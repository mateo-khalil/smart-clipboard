#if E2E
import AppKit
import ApplicationServices
import ClipCore
import ClipPlatform
import ClipStore

/// Drives the real app with real key and mouse events. Compiled only with
/// `-DE2E`, through scripts/e2e/run.sh, and never part of the installed app.
@MainActor
final class EndToEnd {
    private let store: Store
    private let panel: PanelController
    private let statusFrame: () -> (frame: NSRect, screen: NSScreen?)?
    private let targetFile: String
    private let reportFile: String
    private let pokePath: String
    /// `slow` runs only the blocked-read check, in a few seconds.
    private let only: String?
    private var lines: [String] = []
    private var failures = 0
    private let startingMouse = NSEvent.mouseLocation

    // Virtual key codes for the U.S. International - PC layout in use.
    private let keyQuote: CGKeyCode = 39
    private let keyGrave: CGKeyCode = 50
    private let keyA: CGKeyCode = 0
    private let keyN: CGKeyCode = 45
    private let keyReturn: CGKeyCode = 36
    private let keyEscape: CGKeyCode = 53
    private let keyDown: CGKeyCode = 125
    private let keyDelete: CGKeyCode = 51

    init(
        store: Store, panel: PanelController, statusFrame: @escaping () -> (frame: NSRect, screen: NSScreen?)?,
        targetFile: String, reportFile: String, pokePath: String, only: String?
    ) {
        self.store = store
        self.panel = panel
        self.statusFrame = statusFrame
        self.targetFile = targetFile
        self.reportFile = reportFile
        self.pokePath = pokePath
        self.only = only
    }

    func start() {
        Task { @MainActor in
            await self.run()
            self.finish()
        }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        if !passed { failures += 1 }
        lines.append("\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    private func press(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String) async {
        let codes: [Character: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "g": 5, "h": 4, "i": 34, "l": 37, "m": 46,
            "n": 45, "o": 31, "p": 35, "r": 15, "t": 17, "u": 32, "z": 6,
        ]
        for character in text {
            if let code = codes[character] { press(code) }
            await wait(0.03)
        }
    }

    private func moveMouse(toX x: CGFloat, fromTop y: CGFloat) {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    }

    private func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private var targetText: String { (try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? "" }
    private var leaked: Bool { FileManager.default.fileExists(atPath: targetFile + ".leak") }
    private var frontPID: pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1 }
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func seed() throws {
        let now = Date()
        func insert(_ item: [String: Data], age: TimeInterval) throws {
            guard case .clip(let clip) = CapturePipeline.capture(
                from: ReplaySource(items: [item]), frontmostApp: "com.e2e", now: now.addingTimeInterval(-age)
            ) else { return }
            try store.insert(clip)
        }
        let rtf = Data(#"{\rtf1\ansi {\b bold beta}}"#.utf8)
        try insert([KnownTypes.text: Data("alpha plain".utf8)], age: 40)
        try insert([KnownTypes.text: Data("bold beta".utf8), KnownTypes.rtf: rtf], age: 30)
        try insert([KnownTypes.text: Data("delta row".utf8)], age: 20)
        try insert([KnownTypes.text: Data("gamma canción".utf8)], age: 10)
    }

    private func run() async {
        do {
            try seed()
        } catch {
            check("seed", false, "\(error)")
            return
        }
        if only == "slow" {
            await checkSlowProvider(target: frontPID)
            return
        }
        check("Accessibility granted to this build", Permissions.accessibilityGranted)
        check("macOS allows posting events", CGPreflightPostEventAccess())
        check("pasteboard readable", Permissions.clipboardAccess == .allowed)
        let target = frontPID

        // Hotkey and focus.
        moveMouse(toX: 400, fromTop: 200)
        await wait(0.2)
        press(7, [.maskShift, .maskCommand])
        await wait(0.4)
        check("⇧⌘X opens the panel", panel.isVisible)
        check("panel takes the keyboard", panel.testIsKey)
        check("previous app stays frontmost", frontPID == target)
        let opened = panel.testFrame
        check("hotkey opens at the cursor", abs(opened.minX - 400) < 3 && abs(opened.maxY - (primaryHeight - 200)) < 3, "\(opened)")
        check("footer is visible at the bottom", panel.testFooterFrame.minY <= 1 && panel.testFooterFrame.height > 90, "\(panel.testFooterFrame)")
        check("list sits above the footer", panel.testListFrame.minY >= panel.testFooterFrame.maxY - 1)

        // Dead keys on U.S. International: ' + a and ~ + n.
        press(keyQuote)
        await wait(0.1)
        press(keyA)
        await wait(0.1)
        press(keyGrave, .maskShift)
        await wait(0.1)
        press(keyN)
        await wait(0.3)
        check("dead keys compose in search", panel.testQuery == "áñ", panel.testQuery)
        press(keyDelete)
        press(keyDelete)
        await wait(0.2)

        // Accent-insensitive search; the top edge must not move.
        await type("cancion")
        await wait(0.3)
        check("\"cancion\" finds \"canción\"", panel.testTitles == ["gamma canción"], "\(panel.testTitles)")
        check("top edge stays while filtering", abs(panel.testFrame.maxY - opened.maxY) < 1, "\(panel.testFrame)")

        // Enter pastes into the app underneath.
        press(keyReturn)
        await wait(0.5)
        check("Enter closes the panel", !panel.isVisible)
        check("Enter pastes into the previous app", targetText.contains("gamma canción"), targetText)
        check("target app kept focus", frontPID == target)

        // ⌥ copies only.
        var before = targetText
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        press(keyDown)
        await wait(0.1)
        press(keyDown)
        await wait(0.1)
        press(keyReturn, .maskAlternate)
        await wait(0.5)
        check("⌥↩ copies without pasting", targetText == before, targetText)
        check("⌥↩ put the item on the clipboard", NSPasteboard.general.string(forType: .string) != nil)

        // ⇧⌘ strips formatting, and the held ⇧ must not become ⇧⌘V.
        before = targetText
        let boldIndex = 3
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        let titles = panel.testTitles
        check("re-selected items moved to the top", titles.first != "gamma canción" || titles.count == 4, "\(titles)")
        if let row = titles.firstIndex(of: "bold beta") {
            for _ in 0..<row {
                press(keyDown)
                await wait(0.06)
            }
        } else {
            check("found rich item", false, "\(boldIndex)")
        }
        press(keyReturn, [.maskShift, .maskCommand])
        await wait(0.5)
        check("⇧⌘↩ pastes the text", targetText.count > before.count && targetText.hasSuffix("bold beta"), targetText)
        check("held ⇧ does not leak into ⌘V", !leaked)
        let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
        check("formatting is stripped", !types.contains(KnownTypes.rtf), "\(types.prefix(4))")

        // Number shortcut.
        before = targetText
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        press(19, [.maskCommand])
        await wait(0.5)
        check("⌘2 pastes the second row", targetText.count > before.count, targetText)

        // Pin and delete.
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        let count = panel.testTitles.count
        press(35, .maskAlternate)
        await wait(0.2)
        check("⌥P pins without typing π", store.pinned().count == 1 && panel.testQuery.isEmpty, panel.testQuery)
        press(keyDown)
        await wait(0.1)
        press(keyDelete, .maskAlternate)
        await wait(0.2)
        check("⌥⌫ deletes the selected row", panel.testTitles.count == count - 1, "\(panel.testTitles)")
        press(keyEscape)
        await wait(0.2)
        check("Esc closes", !panel.isVisible)

        // Near the bottom edge the panel must slide up and stay on screen.
        moveMouse(toX: 300, fromTop: primaryHeight - 12)
        await wait(0.2)
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        check("stays on screen at the bottom edge", visible.contains(panel.testFrame), "\(panel.testFrame) in \(visible)")
        press(keyEscape)
        await wait(0.2)

        // Near the right edge too.
        moveMouse(toX: (NSScreen.screens.first?.frame.width ?? 0) - 6, fromTop: 300)
        await wait(0.2)
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        check("stays on screen at the right edge", visible.contains(panel.testFrame), "\(panel.testFrame)")
        press(keyEscape)
        await wait(0.2)

        // A real click on the menu bar icon anchors under the icon.
        if let item = statusFrame() {
            let point = CGPoint(x: item.frame.midX, y: primaryHeight - item.frame.midY)
            click(at: point)
            await wait(0.4)
            check("clicking the icon opens the panel", panel.isVisible)
            let frame = panel.testFrame
            // Clamped to the visible frame, so the gap includes the screen margin.
            let gap = item.frame.minY - frame.maxY
            check("panel opens right below the icon", gap >= 0 && gap <= 8, "gap \(gap)")
            check("panel is horizontally at the icon", frame.minX <= item.frame.midX && frame.maxX >= item.frame.minX - 4, "\(frame)")
            click(at: point)
            await wait(0.4)
            check("clicking the icon again closes it", !panel.isVisible)
        } else {
            check("status item present", false)
        }

        // ⌘, opens Settings from the panel.
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        press(43, .maskCommand)
        await wait(0.5)
        let settings = NSApp.windows.first { $0.isVisible && $0.title == "General" }
        check("⌘, opens Preferences", settings != nil)
        settings?.close()
        await wait(0.2)
        await focusTarget()

        // The blocked read goes first: it needs the target focused, and getting
        // focus back after Finder is unreliable.
        await checkSlowProvider(target: target)
        await checkFinderSelection(target: target)

        // The second press is required, so one press must not clear anything.
        await focusTarget()
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        let beforeClear = store.stats().items
        press(keyDelete, [.maskAlternate, .maskShift, .maskCommand])
        await wait(0.2)
        check("one press of Clear all clears nothing", store.stats().items == beforeClear)
        press(keyDelete, [.maskAlternate, .maskShift, .maskCommand])
        await wait(0.3)
        check("second press clears, pins survive", store.stats().items == store.stats().pinned, "\(store.stats())")
        press(keyEscape)
        await wait(0.2)
    }

    /// `activateFileViewerSelecting` gives a genuine Finder multi-selection.
    private func checkFinderSelection(target: pid_t) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sc-e2e-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["one file.txt", "two.txt"].map { directory.appendingPathComponent($0) }
        urls.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data("x".utf8)) }

        // An inactive app may not activate another, but `open` may.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Finder"]
        try? opener.run()
        opener.waitUntilExit()
        await wait(0.8)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        await wait(1.6)
        check("Finder came forward", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
        press(8, .maskCommand)
        await wait(1.3)
        let row = store.page(sort: .lastCopy, limit: 1).first
        check("Finder copy is stored as a file item", row?.kind == .file, row?.title ?? "none")
        let representations = row.flatMap { try? store.representations(id: $0.id) } ?? []
        check("both Finder files are kept", representations.filter { $0.uti == KnownTypes.fileURL }.count == 2, "\(representations.count)")
        if row?.kind == .file {
            onWrite(Paster.write(representations, plainTextOnly: false))
            let restored = NSPasteboard.general.pasteboardItems?.count ?? 0
            let read = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count ?? 0
            check("writing back restores both files", restored == 2 && read == 2, "items \(restored), urls \(read)")
        }
        press(13, .maskCommand)
        await wait(0.4)
        await focusTarget()
    }

    /// The target's window has a fixed position, so a real click refocuses it.
    private func focusTarget() async {
        click(at: CGPoint(x: 1_110, y: primaryHeight - 630))
        await wait(0.5)
    }

    var onWrite: (Int) -> Void = { _ in }

    /// A provider that blocks the capture read must not block pasting.
    private func checkSlowProvider(target: pid_t) async {
        check("target is frontmost before the blocked read", frontPID == target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pokePath)
        process.arguments = ["slow", "3"]
        try? process.run()
        await wait(1.0)
        let before = targetText
        let start = Date()
        press(7, [.maskShift, .maskCommand])
        await wait(0.3)
        check("panel opens during a blocked read", panel.isVisible)
        // The newest row may be the Finder copy, which a text view would not accept.
        if let row = panel.testTitles.firstIndex(of: "delta row") {
            for _ in 0..<row {
                press(keyDown)
                await wait(0.05)
            }
        }
        press(keyReturn)
        await wait(0.6)
        let selected = Date().timeIntervalSince(start)
        check("no stall during a blocked read", selected < 1.9, String(format: "%.2fs", selected))
        let readStart = Date()
        let clipboard = NSPasteboard.general.string(forType: .string)
        let readTime = Date().timeIntervalSince(readStart)
        check("clipboard holds the selection", clipboard == "delta row", "\(clipboard ?? "nil"), read took \(String(format: "%.2f", readTime))s")
        let early = targetText.count > before.count
        check("paste lands during the blocked read", early, targetText)
        process.waitUntilExit()
        await wait(1.5)
        check("paste lands by the time the provider answers", targetText.hasSuffix("delta row"), targetText)
        lines.append("INFO  provider finished after \(String(format: "%.2f", Date().timeIntervalSince(start)))s from opening")
    }

    private func finish() {
        CGWarpMouseCursorPosition(CGPoint(x: startingMouse.x, y: primaryHeight - startingMouse.y))
        lines.append("\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: reportFile, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
#endif
