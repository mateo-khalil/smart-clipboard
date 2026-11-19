import AppKit
import ClipCore
import ClipPlatform
import ClipStore
import Darwin
import os

/// Runs the retention purge at most once an hour after a capture, so the
/// cleanup needs no timer of its own.
private final class PurgeSchedule: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: Date.distantPast)

    func claimIfDue(now: Date = Date(), every interval: TimeInterval = 3_600) -> Bool {
        last.withLock { value in
            guard now.timeIntervalSince(value) >= interval else { return false }
            value = now
            return true
        }
    }
}

@MainActor
public enum SmartClipboardApp {
    public static func run() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { application.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private let schedule = PurgeSchedule()
    private var store: Store?
    private var monitor: ClipboardMonitor?
    private var panel: PanelController?
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var setup: SetupWindowController?
    /// Keeps a snapshot's controller alive until the image is written.
    var retained: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherInstanceIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        let store: Store
        do {
            store = try Store(directory: testDirectory ?? Store.defaultDirectory)
        } catch {
            fail("SmartClipboard could not open its history", detail: "\(error)")
            return
        }
        self.store = store

        let panel = PanelController(store: store, preferences: preferences)
        self.panel = panel
        wire(panel)

        let policy = preferences
        let schedule = schedule
        let monitor = ClipboardMonitor(preferences: preferences, stagingDirectory: store.stagingDirectory) { clip, staging in
            Self.save(clip, stagedIn: staging, store: store, preferences: policy, schedule: schedule)
            // Only the title crosses over: capturing `clip` would keep its payload alive.
            let title = clip.title
            Task { @MainActor [weak panelRef = panel] in
                panelRef?.historyDidChange()
                NotificationCenter.default.post(name: .smartClipboardCaptured, object: title)
            }
        }
        self.monitor = monitor
        monitor.start()

        setUpStatusItem()
        GlobalHotKey.shared.handler = { [weak self] in self?.panel?.toggle(from: .hotkey) }
        if !GlobalHotKey.shared.register(preferences.openShortcut) {
            Toast.show("That shortcut is taken by another app. Pick a new one in Preferences.")
        }
        updateScrollReverser(announceFailure: false)
        observeChanges()
        Self.maintain(store: store, preferences: preferences)

        if CommandLine.arguments.contains("--bench-open") {
            runOpenBench()
            return
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 2 {
            panel.prewarm()
            runSnapshot(kind: arguments[index + 1], path: arguments[index + 2], panel: panel)
            return
        }
        #if E2E
        if let index = arguments.firstIndex(of: "--e2e"), arguments.count > index + 3 {
            panel.prewarm()
            let test = EndToEnd(
                store: store, panel: panel, statusFrame: { [weak self] in self?.statusFrame() },
                targetFile: arguments[index + 1], reportFile: arguments[index + 2], pokePath: arguments[index + 3],
                only: arguments.count > index + 4 ? arguments[index + 4] : nil
            )
            test.onWrite = { [weak self] change in self?.monitor?.noteOwnWrite(changeCount: change) }
            retained = test
            test.start()
            return
        }
        #endif
        if testDirectory == nil { firstRun() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { panel.prewarm() }
        }
    }

    var preferencesForSnapshot: Preferences { preferences }
    var storeForSnapshot: Store? { store }

    /// `--data-dir <path>` points a test run at a throwaway history. It also
    /// skips first-run behavior, so tests never touch the login item or Setup.
    private var testDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--data-dir"), arguments.count > index + 1 else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if preferences.clearHistoryOnQuit { try? store?.clearAll() }
        if preferences.clearClipboardOnQuit { Paster.clearSystemClipboard() }
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() }
    }

    private func fail(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func firstRun() {
        if !preferences.loginDefaultApplied {
            preferences.loginDefaultApplied = true
            LoginItem.setEnabled(true)
        }
        if !preferences.setupCompleted { showSetup() }
    }

    private func wire(_ panel: PanelController) {
        panel.onOwnWrite = { [weak self] change in self?.monitor?.noteOwnWrite(changeCount: change) }
        panel.onPreferences = { [weak self] in self?.showSettings() }
        panel.onAbout = { [weak self] in self?.showAbout() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onNeedsAccessibility = { [weak self] in self?.showSetup() }
        panel.statusItemFrame = { [weak self] in self?.statusFrame() }
    }

    // MARK: Background work

    /// `nonisolated`: runs on the capture queue, away from the main actor.
    private nonisolated static func save(
        _ clip: CapturedClip, stagedIn staging: URL?, store: Store, preferences: Preferences, schedule: PurgeSchedule
    ) {
        _ = try? store.insert(clip, stagedIn: staging)
        if schedule.claimIfDue() { _ = try? store.purge(policy: preferences.retention) }
    }

    private nonisolated static func maintain(store: Store, preferences: Preferences) {
        let policy = preferences.retention
        DispatchQueue.global(qos: .utility).async {
            _ = try? store.sweepOrphans()
            _ = try? store.purge(policy: policy)
            releaseFreeMemory()
        }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        center.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        center.addObserver(forName: .smartClipboardCaptured, object: nil, queue: .main) { [weak self] note in
            let title = note.object as? String
            MainActor.assumeIsolated { self?.updateRecentTitle(title) }
        }
        // A Mac asleep for days still has to expire items when it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let store = self.store else { return }
                Self.maintain(store: store, preferences: self.preferences)
            }
        }
    }

    private var registeredShortcut: KeyCombo?

    private func preferencesChanged() {
        let shortcut = preferences.openShortcut
        if shortcut != registeredShortcut {
            registeredShortcut = shortcut
            if !GlobalHotKey.shared.register(shortcut) {
                Toast.show("That shortcut is taken by another app.")
            }
        }
        monitor?.reschedule()
        updateStatusItem()
        updateScrollReverser(announceFailure: true)
    }

    private var scrollReverserWanted = false

    /// Retried on every preference change and when Setup closes, which is
    /// where Accessibility gets granted.
    private func updateScrollReverser(announceFailure: Bool) {
        let wanted = preferences.reverseMouseScroll
        defer { scrollReverserWanted = wanted }
        if ScrollReverser.shared.setEnabled(wanted) { return }
        if announceFailure && !scrollReverserWanted {
            Toast.show("Mouse scrolling needs Accessibility. Grant it in Setup.")
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        registeredShortcut = preferences.openShortcut
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "SmartClipboard")
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeft
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.isVisible = preferences.showMenuIcon
        statusItem?.button?.appearsDisabled = preferences.paused || Permissions.clipboardAccess == .denied
        if !preferences.showRecentInMenuBar { statusItem?.button?.title = "" }
    }

    private func updateRecentTitle(_ title: String?) {
        guard preferences.showRecentInMenuBar, let title else { return }
        let shown = TextTools.displayTitle(title, specialSymbols: false)
        statusItem?.button?.title = shown.count > 24 ? " " + shown.prefix(24) + "…" : " " + shown
    }

    private func statusFrame() -> (frame: NSRect, screen: NSScreen?)? {
        guard preferences.showMenuIcon, let window = statusItem?.button?.window else { return nil }
        return (window.frame, window.screen)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            preferences.paused.toggle()
            Toast.show(preferences.paused ? "Paused: copies are not being saved" : "Saving copies again")
            return
        }
        // The click that dismissed the panel must not reopen it right away.
        guard let panel, Date().timeIntervalSince(panel.lastHide) > 0.2 else { return }
        if let item = statusFrame() {
            panel.toggle(from: .statusItem(frame: item.frame, screen: item.screen))
        } else {
            panel.toggle(from: .hotkey)
        }
    }

    private func showStatusMenu() {
        panel?.hide()
        let menu = NSMenu()
        if Permissions.clipboardAccess == .denied {
            menu.addItem(item("⚠︎ Clipboard access is blocked", #selector(openSetup)))
        }
        if !Permissions.accessibilityGranted {
            menu.addItem(item("⚠︎ Paste needs Accessibility", #selector(openSetup)))
        }
        if preferences.reverseMouseScroll && !ScrollReverser.shared.isRunning {
            menu.addItem(item("⚠︎ Mouse scrolling needs Accessibility", #selector(openSetup)))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(item(preferences.paused ? "Resume" : "Pause", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Setup…", #selector(openSetup)))
        menu.addItem(item("Preferences…", #selector(openPreferences)))
        menu.addItem(item("About", #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePause() { preferences.paused.toggle() }
    @objc private func openSetup() { showSetup() }
    @objc private func openPreferences() { showSettings() }
    @objc private func openAbout() { showAbout() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    private func showSettings() {
        panel?.hide()
        guard let store else { return }
        if settings == nil {
            let controller = SettingsWindowController(store: store, preferences: preferences)
            controller.onOpenSetup = { [weak self] in self?.showSetup() }
            controller.onHistoryChanged = { [weak self] in self?.panel?.historyDidChange() }
            controller.onClose = { [weak self] in self?.releaseSettings() }
            settings = controller
            controller.present()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func releaseSettings() {
        // Deferred: the window is still inside its close callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.settings = nil
                releaseFreeMemory()
            }
        }
    }

    private func showSetup() {
        panel?.hide()
        if setup == nil {
            let controller = SetupWindowController(preferences: preferences)
            controller.onClose = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.setup = nil
                        self?.updateScrollReverser(announceFailure: false)
                        releaseFreeMemory()
                    }
                }
            }
            setup = controller
            controller.present()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showAbout() {
        panel?.hide()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: Benchmark

    /// `--bench-open [cycles]`: prints open latency and footprint, then quits.
    private func runOpenBench() {
        let arguments = CommandLine.arguments
        let index = arguments.firstIndex(of: "--bench-open") ?? 0
        let cycles = arguments.count > index + 1 ? Int(arguments[index + 1]) ?? 200 : 200
        guard let panel else { return }
        panel.prewarm()
        var times: [Double] = []

        func footprint() -> Double {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
        }

        func step(_ remaining: Int) {
            let start = DispatchTime.now().uptimeNanoseconds
            panel.show(from: .hotkey)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated {
                    panel.hide()
                    releaseFreeMemory()
                    if remaining > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            MainActor.assumeIsolated { step(remaining - 1) }
                        }
                    } else {
                        let sorted = times.sorted()
                        print(String(
                            format: "open first=%.1fms p50=%.1fms p95=%.1fms max=%.1fms footprint=%.1fMB",
                            times[0], sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted[sorted.count - 1], footprint()
                        ))
                        fflush(stdout)
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                print(String(format: "prewarmed footprint=%.1fMB", footprint()))
                step(cycles)
            }
        }
    }
}

private extension Notification.Name {
    static let smartClipboardCaptured = Notification.Name("com.mateoduran.smartclipboard.captured")
}
