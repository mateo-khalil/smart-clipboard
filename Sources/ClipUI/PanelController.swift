import AppKit
import ClipCore
import ClipPlatform
import ClipStore

/// Where a panel request came from, which decides where the panel appears.
enum PanelOrigin {
    case hotkey
    case statusItem(frame: NSRect, screen: NSScreen?)
}

/// The history window. It exists once and is only hidden: measured, this
/// matches destroying it in memory while opening faster and peaking lower.
/// Rows and images are dropped shortly after it closes.
@MainActor
final class PanelController: NSObject {
    private static let pageSize = 60
    private static let searchLimit = 100
    private static let textRowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 46
    private static let footerItemHeight: CGFloat = 24
    private static let footerPadding: CGFloat = 9
    private static let edgeMargin: CGFloat = 4
    private static let rowDropDelay: TimeInterval = 30
    /// Above this, the helper writes the pasteboard, so the bytes never enter this process.
    private static let helperPasteThreshold: Int64 = 512 * 1024
    private static let pinLetters = Array("bcdefghijklmnoqrstuwy").map(String.init)
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
    ]

    private let store: Store
    private let preferences: Preferences
    private let preview: PreviewController

    /// Reports a write to the pasteboard, so it is not recorded as a new copy.
    var onOwnWrite: ((Int) -> Void)?
    var onPreferences: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?
    var onNeedsAccessibility: (() -> Void)?
    var statusItemFrame: (() -> (frame: NSRect, screen: NSScreen?)?)?

    private var panel: ClipPanel?
    private var root: NSVisualEffectView?
    private var table: ClipTableView?
    private var scroll: NSScrollView?
    private var searchField: NSSearchField?
    private var titleLabel: NSTextField?
    private var footer: NSView?
    private var clearItem: FooterItem?

    private var rows: [ClipRow] = []
    private var digitRows: [Int] = []
    private var cursor: PageCursor?
    private var exhausted = true
    private var query = ""
    private var searchGeneration = 0
    private var searchToken: CancelToken?
    private var appIcons: [String: NSImage] = [:]

    private var isPlacing = false
    private var mouseMonitor: Any?
    private var rowDrop: DispatchWorkItem?
    private var clearArmed = false
    private var clearDisarm: DispatchWorkItem?
    private(set) var lastHide = Date.distantPast

    init(store: Store, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        preview = PreviewController(store: store)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }
    var snapshotView: NSView? { root }

    // MARK: Showing and hiding

    func toggle(from origin: PanelOrigin) {
        if isVisible {
            hide()
        } else {
            show(from: origin)
        }
    }

    /// Returns once the frame is committed, so the caller can time the opening.
    func show(from origin: PanelOrigin) {
        rowDrop?.cancel()
        let panel = ensureBuilt()
        clearQuery()
        reload()
        layoutChrome()
        place(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        panel.contentView?.displayIfNeeded()
        CATransaction.flush()
        installMouseMonitor()
    }

    func hide() {
        guard isVisible else { return }
        lastHide = Date()
        preview.dismiss()
        removeMouseMonitor()
        disarmClear()
        panel?.orderOut(nil)
        scheduleRowDrop(after: Self.rowDropDelay)
    }

    /// Renders once, invisibly, so the first real opening does not pay for
    /// loading fonts and AppKit (412 ms measured without this).
    func prewarm() {
        let panel = ensureBuilt()
        reload()
        layoutChrome()
        place(.hotkey)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.contentView?.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
        scheduleRowDrop(after: 0.5)
    }

    func historyDidChange() {
        guard isVisible, query.isEmpty else { return }
        let selected = selectedRow?.id
        reload()
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { select(index) }
        fitHeight()
    }

    private func scheduleRowDrop(after delay: TimeInterval) {
        rowDrop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dropRows() }
        }
        rowDrop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dropRows() {
        guard !isVisible else { return }
        rows = []
        digitRows = []
        appIcons = [:]
        cursor = nil
        table?.reloadData()
        releaseFreeMemory()
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Position

    /// Clicking the icon opens the panel under the icon, on that screen. The
    /// hotkey follows the Appearance setting, which defaults to the cursor.
    private func place(_ origin: PanelOrigin) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        var screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var left = mouse.x
        var top = mouse.y
        let width = CGFloat(preferences.panelWidth)
        var height = preferredHeight()

        func anchor(to frame: NSRect, on anchorScreen: NSScreen?) {
            screen = anchorScreen ?? screen
            left = frame.minX
            top = frame.minY - 2
        }

        switch origin {
        case .statusItem(let frame, let itemScreen):
            anchor(to: frame, on: itemScreen)
        case .hotkey:
            switch preferences.popupPosition {
            case .cursor:
                break
            case .statusItem:
                if let item = statusItemFrame?() { anchor(to: item.frame, on: item.screen) }
            case .screenCenter:
                if let visible = screen?.visibleFrame {
                    left = visible.midX - width / 2
                    top = visible.midY + height / 2
                }
            case .lastPosition:
                if let last = preferences.panelTopLeft {
                    left = last.x
                    top = last.y
                    screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: left, y: top - 1), $0.frame, false) } ?? screen
                }
            }
        }

        guard let visible = screen?.visibleFrame else { return }
        let margin = Self.edgeMargin
        height = min(height, visible.height - margin * 2)
        left = min(max(left, visible.minX + margin), visible.maxX - width - margin)
        top = min(top, visible.maxY - margin)
        // Too close to the bottom edge: slide up rather than cutting the list short.
        if top - height < visible.minY + margin { top = visible.minY + margin + height }

        isPlacing = true
        panel.setFrame(NSRect(x: left, y: top - height, width: width, height: height), display: false)
        isPlacing = false
    }

    private func preferredHeight() -> CGFloat {
        let limit = CGFloat(preferences.panelHeight)
        let chrome = chromeHeight() + 8
        var body: CGFloat = 0
        for row in rows {
            body += height(of: row)
            if chrome + body >= limit { return limit }
        }
        return min(limit, chrome + max(body, Self.textRowHeight * 2))
    }

    /// Resizes from the bottom: the top edge stays put while results change.
    private func fitHeight() {
        guard let panel else { return }
        let frame = panel.frame
        let top = frame.maxY
        let visible = panel.screen?.visibleFrame ?? frame
        let height = min(preferredHeight(), top - visible.minY - Self.edgeMargin)
        guard abs(height - frame.height) > 0.5 else { return }
        isPlacing = true
        panel.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
        isPlacing = false
    }

    private func chromeHeight() -> CGFloat {
        headerHeight() + footerHeight()
    }

    private func headerHeight() -> CGFloat {
        preferences.showSearch || preferences.showTitle ? Self.headerHeight : 0
    }

    private func footerHeight() -> CGFloat {
        preferences.showFooter ? Self.footerItemHeight * 4 + Self.footerPadding : 0
    }

    // MARK: Building

    private func ensureBuilt() -> ClipPanel {
        if let panel { return panel }
        let frame = NSRect(x: 0, y: 0, width: preferences.panelWidth, height: preferences.panelHeight)
        let panel = ClipPanel(
            contentRect: frame, styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.minSize = NSSize(width: 280, height: 220)
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let root = NSVisualEffectView(frame: frame)
        root.material = .menu
        root.state = .active
        root.blendingMode = .behindWindow
        root.maskImage = roundedMask(radius: 12)
        root.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Clipboard")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        root.addSubview(title)

        let search = NSSearchField(frame: .zero)
        search.placeholderString = "Type to search…"
        search.focusRingType = .none
        search.delegate = self
        root.addSubview(search)

        let table = ClipTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.onHover = { [weak self] row in self?.select(row, scrolling: false) }
        table.onClick = { [weak self] row, flags in self?.activate(row: row, flags: flags) }

        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        root.addSubview(scroll)

        let footer = NSView(frame: .zero)
        let separator = NSBox(frame: .zero)
        separator.boxType = .separator
        separator.identifier = NSUserInterfaceItemIdentifier("separator")
        footer.addSubview(separator)
        let clear = FooterItem(title: "Clear all", shortcut: "⌥⇧⌘⌫") { [weak self] in self?.requestClearAll() }
        let items = [
            clear,
            FooterItem(title: "Preferences…", shortcut: "⌘,") { [weak self] in self?.onPreferences?() },
            FooterItem(title: "About", shortcut: "") { [weak self] in self?.onAbout?() },
            FooterItem(title: "Quit", shortcut: "⌘Q") { [weak self] in self?.onQuit?() },
        ]
        items.forEach(footer.addSubview)
        root.addSubview(footer)

        panel.contentView = root
        self.panel = panel
        self.root = root
        self.table = table
        self.scroll = scroll
        self.searchField = search
        self.titleLabel = title
        self.footer = footer
        self.clearItem = clear
        return panel
    }

    /// The footer is anchored to the bottom and the list takes what remains,
    /// so Preferences and Quit stay visible however long the history gets.
    private func layoutChrome() {
        guard let root, let scroll, let footer, let searchField, let titleLabel else { return }
        let bounds = root.bounds
        let header = headerHeight()
        let bottom = footerHeight()

        let showTitle = preferences.showTitle
        titleLabel.isHidden = !showTitle
        var searchX: CGFloat = 12
        if showTitle {
            titleLabel.sizeToFit()
            titleLabel.frame.origin = NSPoint(x: 14, y: bounds.height - header + (header - titleLabel.frame.height) / 2)
            searchX = titleLabel.frame.maxX + 10
        }
        searchField.frame = NSRect(x: searchX, y: bounds.height - header + 9, width: bounds.width - searchX - 10, height: 28)
        // With the field hidden, typing still reaches it and filters the list.
        searchField.alphaValue = preferences.showSearch ? 1 : 0

        scroll.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: max(0, bounds.height - header - bottom - 2))
        footer.isHidden = !preferences.showFooter
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bottom)
        var y = 2 + Self.footerItemHeight * 3
        for view in footer.subviews {
            if view is NSBox {
                view.frame = NSRect(x: 12, y: bottom - 3, width: bounds.width - 24, height: 1)
            } else {
                view.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.footerItemHeight)
                y -= Self.footerItemHeight
            }
        }
    }

    // MARK: Data

    private var pinsOnTop: Bool { preferences.pinPlacement == .top }

    private func reload() {
        let sort = preferences.sortOrder
        let history = store.page(sort: sort, limit: Self.pageSize)
        let pins = store.pinned()
        cursor = history.last.map { Store.cursor(after: $0, sort: sort) }
        exhausted = history.count < Self.pageSize
        rows = pinsOnTop ? pins + history : history + (exhausted ? pins : [])
        didChangeRows()
    }

    private func didChangeRows(selecting index: Int = 0) {
        digitRows = Array(rows.indices.filter { rows[$0].pinKey == nil }.prefix(9))
        table?.reloadData()
        if !rows.isEmpty { select(min(index, rows.count - 1)) }
    }

    private func loadNextPage() {
        guard query.isEmpty, !exhausted, let cursor else { return }
        let sort = preferences.sortOrder
        let page = store.page(sort: sort, after: cursor, limit: Self.pageSize)
        self.cursor = page.last.map { Store.cursor(after: $0, sort: sort) }
        exhausted = page.count < Self.pageSize
        let selected = table?.selectedRow ?? 0
        rows += page
        if exhausted, !pinsOnTop { rows += store.pinned() }
        digitRows = Array(rows.indices.filter { rows[$0].pinKey == nil }.prefix(9))
        table?.noteNumberOfRowsChanged()
        if selected >= 0 { select(selected, scrolling: false) }
    }

    private func clearQuery() {
        query = ""
        searchField?.stringValue = ""
        searchToken?.cancel()
        searchGeneration += 1
    }

    /// `nonisolated` keeps the blocking scan off the main actor.
    private nonisolated static func runSearch(
        store: Store, query: String, mode: SearchMode, sort: HistorySort, limit: Int, token: CancelToken,
        completion: @escaping @MainActor @Sendable ([ClipRow]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = store.search(query: query, mode: mode, sort: sort, limit: limit, token: token)
            guard !token.isCancelled else { return }
            Task { @MainActor in completion(rows) }
        }
    }

    private func applyQuery(_ text: String) {
        query = text
        searchToken?.cancel()
        searchGeneration += 1
        guard !text.isEmpty else {
            reload()
            fitHeight()
            return
        }
        let token = CancelToken()
        searchToken = token
        let generation = searchGeneration
        Self.runSearch(
            store: store, query: text, mode: preferences.searchMode, sort: preferences.sortOrder,
            limit: Self.searchLimit, token: token
        ) { [weak self] found in
            guard let self, generation == self.searchGeneration else { return }
            self.exhausted = true
            self.cursor = nil
            self.rows = found
            self.didChangeRows()
            self.fitHeight()
        }
    }

    private func height(of row: ClipRow) -> CGFloat {
        guard row.kind == .image, row.thumbHeight > 0 else { return Self.textRowHeight }
        let image = min(CGFloat(preferences.imageHeight), CGFloat(row.thumbHeight) / 2)
        return max(Self.textRowHeight, image + 6)
    }

    // MARK: Selection and keyboard

    private var selectedRow: ClipRow? {
        guard let index = table?.selectedRow, rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    private func select(_ index: Int, scrolling: Bool = true) {
        guard let table, rows.indices.contains(index) else { return }
        if table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if scrolling { table.scrollRowToVisible(index) }
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        select(max(0, min(rows.count - 1, (table?.selectedRow ?? 0) + delta)))
    }

    private func matches(_ event: NSEvent, _ combo: KeyCombo?) -> Bool {
        guard let combo else { return false }
        return UInt32(event.keyCode) == combo.keyCode && carbonModifiers(event.modifierFlags) == combo.modifiers
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // A dead key in progress (´ before a vowel) belongs to the text system.
        if let editor = searchField?.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if matches(event, preferences.pinShortcut) {
            togglePin()
            return true
        }
        if matches(event, preferences.deleteShortcut) {
            deleteSelected()
            return true
        }
        if event.keyCode == 51, flags == [.option, .shift, .command] {
            requestClearAll()
            return true
        }

        switch event.keyCode {
        case 53:
            hide()
            return true
        case 36, 76:
            if let index = table?.selectedRow, index >= 0 { activate(row: index, flags: event.modifierFlags) }
            return true
        case 126:
            flags.contains(.command) ? select(0) : move(by: -1)
            return true
        case 125:
            flags.contains(.command) ? select(rows.count - 1) : move(by: 1)
            return true
        case 116:
            move(by: -10)
            return true
        case 121:
            move(by: 10)
            return true
        default:
            break
        }

        if flags == [.control], key == "n" || key == "p" {
            move(by: key == "n" ? 1 : -1)
            return true
        }

        if flags == [.command] {
            switch key {
            case ",":
                onPreferences?()
                return true
            case "q":
                onQuit?()
                return true
            case "a": return sendToField(#selector(NSText.selectAll(_:)))
            case "c": return sendToField(#selector(NSText.copy(_:)))
            case "x": return sendToField(#selector(NSText.cut(_:)))
            case "v": return sendToField(#selector(NSText.paste(_:)))
            case "z": return sendToField(Selector(("undo:")))
            default: break
            }
        }

        if let digit = Self.digitKeyCodes[event.keyCode],
           flags == [.command] || flags == [.option] || flags == [.shift, .command],
           digitRows.indices.contains(digit) {
            activate(row: digitRows[digit], flags: event.modifierFlags)
            return true
        }

        if flags == [.shift, .command], let index = rows.firstIndex(where: { $0.pinKey == key }) {
            activate(row: index, flags: event.modifierFlags)
            return true
        }
        return false
    }

    /// With no main menu, editing shortcuts must be routed by hand.
    private func sendToField(_ action: Selector) -> Bool {
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }

    // MARK: Actions

    private func activate(row index: Int, flags: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]

        var paste = preferences.pasteAutomatically
        var strip = preferences.pasteWithoutFormatting
        switch flags.intersection([.command, .option, .shift]) {
        case [.option]:
            paste = false
        case [.command]:
            paste = true
        case [.shift, .command]:
            paste = true
            strip = true
        default:
            break
        }

        guard let entries = try? store.pasteEntries(id: row.id), !entries.isEmpty else {
            hide()
            Toast.show("This item's data is missing")
            return
        }
        hide()
        try? store.touch(id: row.id)

        if row.byteSize > Self.helperPasteThreshold, Helper.isAvailable {
            Self.writeThroughHelper(entries, plainTextOnly: strip) { [weak self] written in
                guard written else {
                    Toast.show("This item could not be restored")
                    return
                }
                self?.onOwnWrite?(NSPasteboard.general.changeCount)
                self?.finishSelection(paste: paste)
            }
        } else {
            let representations = entries.compactMap(Helper.representation(from:))
            onOwnWrite?(Paster.write(representations, plainTextOnly: strip))
            finishSelection(paste: paste)
        }
    }

    /// `nonisolated`: waiting for the helper must not hold up the main actor.
    private nonisolated static func writeThroughHelper(
        _ entries: [PasteEntry], plainTextOnly: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            let written = Helper.paste(entries, plainTextOnly: plainTextOnly)
            Task { @MainActor in completion(written) }
        }
    }

    private func finishSelection(paste: Bool) {
        guard paste else { return }
        guard Permissions.accessibilityGranted else {
            Toast.show("Copied. Allow Accessibility to paste automatically.")
            onNeedsAccessibility?()
            return
        }
        if Permissions.secureInputActive {
            Toast.show("Copied. Secure input is on, press ⌘V to paste.")
            return
        }
        // The previous app must get the keyboard back before it receives ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { _ = Paster.postPaste() }
        }
    }

    private func togglePin() {
        guard let row = selectedRow else { return }
        if row.pinKey != nil {
            try? store.setPin(id: row.id, key: nil)
        } else {
            let used = Set(store.pinned().compactMap(\.pinKey))
            guard let letter = Self.pinLetters.first(where: { !used.contains($0) }) else {
                Toast.show("No free pin letters")
                return
            }
            try? store.setPin(id: row.id, key: letter)
        }
        if query.isEmpty {
            reload()
            if let index = rows.firstIndex(where: { $0.id == row.id }) { select(index) }
        } else {
            applyQuery(query)
        }
    }

    private func deleteSelected() {
        guard let table, let row = selectedRow else { return }
        let index = table.selectedRow
        try? store.delete(id: row.id)
        rows.remove(at: index)
        didChangeRows(selecting: index)
        fitHeight()
    }

    /// Clearing is irreversible and has a shortcut, so it takes two presses.
    private func requestClearAll() {
        guard clearArmed else {
            clearArmed = true
            clearItem?.title = "Press again to clear"
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.disarmClear() }
            }
            clearDisarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        disarmClear()
        try? store.clearAll()
        clearQuery()
        reload()
        fitHeight()
    }

    private func disarmClear() {
        clearDisarm?.cancel()
        clearArmed = false
        clearItem?.title = "Clear all"
    }

    private func schedulePreview() {
        guard let table, let row = selectedRow else {
            preview.dismiss()
            return
        }
        let index = table.selectedRow
        preview.schedule(row: row, delayMs: preferences.previewDelayMs) { [weak table] in
            guard let table, index < table.numberOfRows else { return nil }
            return (table, table.rect(ofRow: index))
        }
    }
}

// MARK: - Table

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? height(of: rows[row]) : Self.textRowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        let cell = tableView.makeView(withIdentifier: ClipCell.identifier, owner: nil) as? ClipCell ?? ClipCell(frame: .zero)

        var image: NSImage?
        if row.kind == .image, row.thumbHeight > 0, let data = store.thumbnail(id: row.id) { image = NSImage(data: data) }

        cell.configure(
            row: row,
            displayTitle: TextTools.displayTitle(row.title, specialSymbols: preferences.showSpecialSymbols),
            highlight: highlightText,
            shortcutText: shortcutText(for: index, row: row),
            image: image,
            imageHeight: CGFloat(preferences.imageHeight),
            icon: preferences.showAppIcons ? appIcon(for: row.sourceApp) : nil
        )

        if index >= rows.count - 20, !exhausted {
            // Deferred: the table is mid-layout and must not change size here.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.loadNextPage() }
            }
        }
        return cell
    }

    private var highlightText: String? {
        guard preferences.highlightMatches, !query.isEmpty else { return nil }
        switch preferences.searchMode {
        case .exact, .mixed: return query
        case .fuzzy, .regexp: return nil
        }
    }

    private func shortcutText(for index: Int, row: ClipRow) -> String? {
        if let key = row.pinKey { return "⇧⌘" + key.uppercased() }
        guard let digit = digitRows.firstIndex(of: index) else { return nil }
        return "⇧⌘\(digit + 1)"
    }

    private func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        appIcons[bundleID] = icon
        return icon
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        schedulePreview()
    }
}

// MARK: - Search field and window

extension PanelController: NSSearchFieldDelegate, NSWindowDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applyQuery(searchField?.stringValue ?? "")
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidResize(_ notification: Notification) {
        layoutChrome()
    }

    func windowDidMove(_ notification: Notification) {
        rememberPosition()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        preferences.panelWidth = Int(frame.width)
        preferences.panelHeight = Int(frame.height)
    }

    private func rememberPosition() {
        guard !isPlacing, let frame = panel?.frame else { return }
        preferences.panelTopLeft = (Double(frame.minX), Double(frame.maxY))
    }
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= KeyCombo.command }
    if flags.contains(.shift) { modifiers |= KeyCombo.shift }
    if flags.contains(.option) { modifiers |= KeyCombo.option }
    if flags.contains(.control) { modifiers |= KeyCombo.control }
    return modifiers
}

#if E2E
extension PanelController {
    var testFrame: NSRect { panel?.frame ?? .zero }
    var testIsKey: Bool { panel?.isKeyWindow == true }
    var testQuery: String { searchField?.stringValue ?? "" }
    var testTitles: [String] { rows.map(\.title) }
    var testFooterFrame: NSRect { footer?.isHidden == false ? footer?.frame ?? .zero : .zero }
    var testListFrame: NSRect { scroll?.frame ?? .zero }
}
#endif
