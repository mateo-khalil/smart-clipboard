import AppKit
import ClipCore
import ClipPlatform
import ClipStore

/// Built on demand and released on close, so Settings costs nothing while closed.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private enum Tab: String, CaseIterable {
        case general, storage, appearance, pins, ignore, advanced

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .storage: return "internaldrive"
            case .appearance: return "paintpalette"
            case .pins: return "pin"
            case .ignore: return "nosign"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private let store: Store
    private let preferences: Preferences
    private let window: NSWindow
    private var factory = ControlFactory()
    private var pinsTable: PinsTable?
    private var listEditors: [ListEditor] = []
    private var usageLabel: NSTextField?
    private var loginStatus: NSTextField?
    private var loginBox: NSButton?
    private var importLabel: NSTextField?

    var onOpenSetup: (() -> Void)?
    var onClose: (() -> Void)?
    /// Called after a change that affects stored items, such as Clear or Import.
    var onHistoryChanged: (() -> Void)?

    init(store: Store, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
    }

    func preparedContent(tab name: String) -> NSView? {
        select(Tab(rawValue: name) ?? .general)
        return window.contentView
    }

    func present() {
        select(.general)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        commitEdits()
        onClose?()
    }

    private func commitEdits() {
        window.makeFirstResponder(nil)
        listEditors.forEach { $0.commit() }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarSelected(_:))
        return item
    }

    @objc private func toolbarSelected(_ sender: NSToolbarItem) {
        if let tab = Tab(rawValue: sender.itemIdentifier.rawValue) { select(tab) }
    }

    private func select(_ tab: Tab) {
        commitEdits()
        factory = ControlFactory()
        pinsTable = nil
        listEditors = []
        usageLabel = nil
        loginStatus = nil
        loginBox = nil
        importLabel = nil

        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        window.title = tab.title
        let content: NSView
        switch tab {
        case .general: content = generalTab()
        case .storage: content = storageTab()
        case .appearance: content = appearanceTab()
        case .pins: content = pinsTab()
        case .ignore: content = ignoreTab()
        case .advanced: content = advancedTab()
        }

        // Resize around the top edge so the toolbar does not jump.
        content.layoutSubtreeIfNeeded()
        // Fitting size omits the stack's trailing inset, so it is added back here.
        let size = NSSize(width: max(520, content.fittingSize.width + 24), height: content.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.contentView = content
        window.setFrame(frame, display: true)
    }

    // MARK: Tabs

    private func generalTab() -> NSView {
        let f = factory
        let box = f.checkbox("Launch at login", isOn: LoginItem.state == .enabled) { [weak self] on in
            LoginItem.setEnabled(on)
            self?.refreshLogin()
        }
        loginBox = box
        let status = f.note("")
        loginStatus = status

        let shortcuts = f.form([
            ("Open:", ShortcutRecorder(combo: preferences.openShortcut) { [preferences] in preferences.openShortcut = $0 }),
            ("Pin:", ShortcutRecorder(combo: preferences.pinShortcut) { [preferences] in preferences.pinShortcut = $0 }),
            ("Delete:", ShortcutRecorder(combo: preferences.deleteShortcut) { [preferences] in preferences.deleteShortcut = $0 }),
        ])
        let search = f.form([
            ("Search:", f.popup(SearchMode.allCases.map(\.title), selected: preferences.searchMode.rawValue) { [preferences] in
                preferences.searchMode = SearchMode(rawValue: $0) ?? .exact
            }),
        ])
        let view = f.page([
            box,
            status,
            f.separator(),
            shortcuts,
            f.separator(),
            search,
            f.separator(),
            f.label("Behavior:"),
            f.checkbox("Paste automatically", isOn: preferences.pasteAutomatically) { [preferences] in preferences.pasteAutomatically = $0 },
            f.checkbox("Paste without formatting", isOn: preferences.pasteWithoutFormatting) { [preferences] in preferences.pasteWithoutFormatting = $0 },
            f.note("""
            Customize the behavior when selecting an item:
            • Select with ⌥ pressed to copy the item.
            • Select with ⌘ pressed to copy and paste the item.
            • Select with ⇧⌘ pressed to copy, clear formatting, and paste the item.
            """),
            f.separator(),
            f.label("Mouse:"),
            f.checkbox("Classic scrolling for the mouse wheel", isOn: preferences.reverseMouseScroll) { [preferences] in preferences.reverseMouseScroll = $0 },
            f.note("The trackpad keeps natural scrolling. Needs Accessibility and natural scrolling turned on in System Settings."),
            f.separator(),
            f.button("Permissions & Setup…") { [weak self] in self?.onOpenSetup?() },
        ])
        refreshLogin()
        return view
    }

    private func refreshLogin() {
        let state = LoginItem.state
        loginBox?.state = state == .enabled ? .on : .off
        switch state {
        case .needsApproval:
            loginStatus?.stringValue = "Waiting for your approval in System Settings > General > Login Items."
        case .unavailable:
            loginStatus?.stringValue = "Move SmartClipboard to /Applications to use this."
        default:
            loginStatus?.stringValue = ""
        }
        loginStatus?.isHidden = loginStatus?.stringValue.isEmpty ?? true
    }

    private func storageTab() -> NSView {
        let f = factory
        let days = [7, 30, 90, 0]
        let dayTitles = ["7 days", "30 days", "90 days", "Never"]
        let usage = f.note("")
        usageLabel = usage
        let view = f.page([
            f.label("Save:"),
            f.checkbox("Files", isOn: preferences.saveFiles) { [preferences] in preferences.saveFiles = $0 },
            f.checkbox("Images", isOn: preferences.saveImages) { [preferences] in preferences.saveImages = $0 },
            f.checkbox("Text", isOn: preferences.saveText) { [preferences] in preferences.saveText = $0 },
            f.note("Change what types of copied content should be stored."),
            f.separator(),
            f.form([
                ("Delete after:", f.popup(dayTitles, selected: days.firstIndex(of: preferences.retentionDays) ?? 1) { [preferences] index in
                    preferences.retentionDays = days[index]
                }),
                ("Max items:", f.number(value: preferences.maxItems, range: 10...1_000_000, step: 500) { [preferences] in preferences.maxItems = $0 }),
                ("Max disk (GB):", f.number(value: preferences.maxDiskGB, range: 1...500) { [preferences] in preferences.maxDiskGB = $0 }),
                ("Sort by:", f.popup(HistorySort.allCases.map(\.title), selected: preferences.sortOrder.rawValue) { [preferences] in
                    preferences.sortOrder = HistorySort(rawValue: $0) ?? .lastCopy
                }),
            ]),
            f.note("Items are deleted that long after their last copy, and copying one again restarts the count. Pinned items never expire. Past either limit, the oldest unpinned items go first."),
            usage,
        ])
        refreshUsage()
        return view
    }

    private func refreshUsage() {
        let stats = store.stats()
        let disk = ByteCountFormatter.string(fromByteCount: stats.diskBytes, countStyle: .file)
        usageLabel?.stringValue = "In use: \(stats.items) items, \(disk) on disk"
    }

    private func appearanceTab() -> NSView {
        let f = factory
        return f.page([
            f.form([
                ("Hotkey opens at:", f.popup(PopupPosition.allCases.map(\.title), selected: preferences.popupPosition.rawValue) { [preferences] in
                    preferences.popupPosition = PopupPosition(rawValue: $0) ?? .cursor
                }),
                ("Pin to:", f.popup(PinPlacement.allCases.map(\.title), selected: preferences.pinPlacement.rawValue) { [preferences] in
                    preferences.pinPlacement = PinPlacement(rawValue: $0) ?? .top
                }),
                ("Image height:", f.number(value: preferences.imageHeight, range: 16...80, step: 4) { [preferences] in preferences.imageHeight = $0 }),
                ("Preview delay (ms):", f.number(value: preferences.previewDelayMs, range: 0...10_000, step: 100) { [preferences] in preferences.previewDelayMs = $0 }),
            ]),
            f.note("Clicking the menu bar icon always opens the panel under the icon. A preview delay of 0 turns previews off."),
            f.separator(),
            f.checkbox("Highlight matches", isOn: preferences.highlightMatches) { [preferences] in preferences.highlightMatches = $0 },
            f.checkbox("Show special symbols", isOn: preferences.showSpecialSymbols) { [preferences] in preferences.showSpecialSymbols = $0 },
            f.checkbox("Show menu icon", isOn: preferences.showMenuIcon) { [preferences] in preferences.showMenuIcon = $0 },
            f.checkbox("Show recent copy in menu bar", isOn: preferences.showRecentInMenuBar) { [preferences] in preferences.showRecentInMenuBar = $0 },
            f.checkbox("Show search field", isOn: preferences.showSearch) { [preferences] in preferences.showSearch = $0 },
            f.checkbox("Show title", isOn: preferences.showTitle) { [preferences] in preferences.showTitle = $0 },
            f.checkbox("Show application icons", isOn: preferences.showAppIcons) { [preferences] in preferences.showAppIcons = $0 },
            f.checkbox("Show footer", isOn: preferences.showFooter) { [preferences] in preferences.showFooter = $0 },
        ])
    }

    private func pinsTab() -> NSView {
        let table = PinsTable(store: store)
        pinsTable = table
        return factory.page([
            factory.note("Press ⌥P in the list to pin an item. Press ⇧⌘ and its letter to use it."),
            table.view,
        ])
    }

    private func ignoreTab() -> NSView {
        let f = factory
        let apps = ListEditor(title: "Applications", lines: preferences.ignoredApps) { [preferences] in preferences.ignoredApps = $0 }
        let types = ListEditor(title: "Pasteboard types", lines: preferences.ignoredTypes) { [preferences] in preferences.ignoredTypes = $0 }
        let patterns = ListEditor(title: "Regular expressions", lines: preferences.ignoredPatterns) { [preferences] in preferences.ignoredPatterns = $0 }
        listEditors = [apps, types, patterns]
        let columns = NSStackView(views: [apps.view, types.view, patterns.view])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 12
        columns.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return f.page([
            f.note("One entry per line. Password manager copies are always ignored. Applications take bundle identifiers, such as com.apple.Safari.", width: 540),
            columns,
            f.button("Add Application…") { [weak self, apps] in self?.chooseApp(into: apps) },
            f.checkbox("Ignore all applications except the listed ones", isOn: preferences.onlyListedApps) { [preferences] in preferences.onlyListedApps = $0 },
        ])
    }

    private func chooseApp(into editor: ListEditor) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.beginSheetModal(for: window) { [weak editor] response in
            guard response == .OK, let url = open.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { editor?.append(bundle) }
        }
    }

    private func advancedTab() -> NSView {
        let f = factory
        let result = f.note("")
        result.isHidden = true
        importLabel = result
        return f.page([
            f.checkbox("Pause saving what you copy", isOn: preferences.paused) { [preferences] in preferences.paused = $0 },
            f.checkbox("Clear history on quit", isOn: preferences.clearHistoryOnQuit) { [preferences] in preferences.clearHistoryOnQuit = $0 },
            f.checkbox("Clear system clipboard on quit", isOn: preferences.clearClipboardOnQuit) { [preferences] in preferences.clearClipboardOnQuit = $0 },
            f.separator(),
            f.form([
                ("Max item size (MiB):", f.number(value: preferences.maxItemMiB, range: 1...1024) { [preferences] in preferences.maxItemMiB = $0 }),
                ("Check every (ms):", f.number(value: preferences.checkIntervalMs, range: 100...5_000, step: 100) { [preferences] in preferences.checkIntervalMs = $0 }),
            ]),
            f.note("Anything larger than the maximum size is not saved."),
            f.separator(),
            f.button("Import from Maccy…") { [weak self] in self?.importFromMaccy() },
            result,
            f.button("Show Data Folder") { [store] in NSWorkspace.shared.open(store.directory) },
        ])
    }

    private nonisolated static func runImport(
        store: Store, retention: RetentionPolicy, options: CaptureOptions,
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                let result = try store.importMaccy(retention: retention, options: options)
                message = "Imported \(result.imported) items, skipped \(result.skipped)."
            } catch {
                message = "Import failed: \(error)"
            }
            Task { @MainActor in completion(message) }
        }
    }

    private func importFromMaccy() {
        importLabel?.stringValue = "Importing…"
        importLabel?.isHidden = false
        Self.runImport(store: store, retention: preferences.retention, options: preferences.captureOptions) { [weak self] message in
            self?.importLabel?.stringValue = message
            self?.onHistoryChanged?()
        }
    }
}

/// One-entry-per-line editor for the Ignore tab.
@MainActor
private final class ListEditor: NSObject, NSTextViewDelegate {
    let view: NSView
    private let textView: NSTextView
    private let save: ([String]) -> Void

    init(title: String, lines: [String], save: @escaping ([String]) -> Void) {
        self.save = save
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        textView = scroll.documentView as! NSTextView
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = lines.joined(separator: "\n")

        let caption = NSTextField(labelWithString: title)
        caption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [caption, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        view = stack
        super.init()
        textView.delegate = self
    }

    func append(_ line: String) {
        let separator = textView.string.isEmpty || textView.string.hasSuffix("\n") ? "" : "\n"
        textView.string += separator + line
        commit()
    }

    func commit() {
        let lines = textView.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        save(lines)
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }
}

/// Lists pins and lets each one change its letter or be removed.
@MainActor
private final class PinsTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let view: NSView
    private let store: Store
    private let table = NSTableView()
    private var rows: [ClipRow] = []

    init(store: Store) {
        self.store = store
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        view = scroll
        super.init()
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.title = "Key"
        key.width = 44
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        title.title = "Item"
        title.width = 340
        let remove = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        remove.title = ""
        remove.width = 60
        [key, title, remove].forEach(table.addTableColumn)
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        reload()
    }

    private func reload() {
        rows = store.pinned()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        switch tableColumn?.identifier.rawValue {
        case "key":
            let field = NSTextField(string: row.pinKey ?? "")
            field.alignment = .center
            field.tag = index
            field.delegate = self
            return field
        case "title":
            let label = NSTextField(labelWithString: TextTools.displayTitle(row.title, specialSymbols: true))
            label.lineBreakMode = .byTruncatingMiddle
            return label
        default:
            let button = NSButton(title: "Unpin", target: self, action: #selector(unpin(_:)))
            button.bezelStyle = .inline
            button.tag = index
            return button
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rows.indices.contains(field.tag) else { return }
        let key = field.stringValue.lowercased()
        let row = rows[field.tag]
        let taken = rows.contains { $0.pinKey == key && $0.id != row.id }
        guard key.count == 1, key.first?.isLetter == true, !taken else {
            field.stringValue = row.pinKey ?? ""
            NSSound.beep()
            return
        }
        try? store.setPin(id: row.id, key: key)
        reload()
    }

    @objc private func unpin(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        try? store.setPin(id: rows[sender.tag].id, key: nil)
        reload()
    }
}
