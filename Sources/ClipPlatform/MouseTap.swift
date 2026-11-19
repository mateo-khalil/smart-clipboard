import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What the mouse tap fixes. Both are off by default.
public struct MouseFixes: Equatable, Sendable {
    /// The wheel scrolls the classic way while the trackpad stays natural.
    public var classicWheel: Bool
    /// The side buttons go back and forward in apps that ignore them.
    public var sideButtons: Bool

    public init(classicWheel: Bool, sideButtons: Bool) {
        self.classicWheel = classicWheel
        self.sideButtons = sideButtons
    }

    public var any: Bool { classicWheel || sideButtons }
}

/// One event tap for the mouse fixes, receiving only the events they need.
///
/// **Wheel.** macOS has a single natural-scrolling switch for the trackpad and
/// the mouse, so the tap flips the wheel's events back. A wheel sends discrete
/// steps and a trackpad (or a Magic Mouse) continuous ones: `isContinuous`
/// tells them apart.
///
/// **Side buttons.** Chrome and Firefox handle buttons 4 and 5 on their own;
/// Safari, Finder and other Apple apps ignore them. In those apps the tap
/// swallows the click and sends ⌘[ or ⌘]. Everywhere else the click passes
/// through untouched, because in an editor ⌘[ means "outdent".
///
/// The tap runs on its own thread. On the main thread, any busy moment of the
/// app would stall the mouse in every app. Idle, the thread sleeps in the
/// kernel: no timer, no polling.
public final class MouseTap: @unchecked Sendable {
    public static let shared = MouseTap()

    /// Apps where ⌘[ and ⌘] are Back and Forward and the side buttons do nothing.
    static let navigationApps: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.finder",
        "com.apple.systempreferences", "com.apple.AppStore",
    ]

    static func navigates(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // Safari web apps added to the Dock.
        return navigationApps.contains(bundleID) || bundleID.hasPrefix("com.apple.Safari.WebApp")
    }

    private static let backButton: Int64 = 3
    private static let forwardButton: Int64 = 4

    private let lock = NSLock()
    // Guarded by `lock`: written on the main thread, read by the tap.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var fixes = MouseFixes(classicWheel: false, sideButtons: false)
    private var frontmostNavigates = false
    private var backKey: CGKeyCode = 33
    private var forwardKey: CGKeyCode = 30

    // Touched only on the tap thread.
    private var naturalScrolling = true
    private var checkedAt: UInt64 = 0
    private var swallowedButtons: Set<Int64> = []

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {}

    public var isRunning: Bool { lock.withLock { tap != nil } }

    /// Returns `false` when the tap cannot be created, which means the app
    /// lacks Accessibility. Calling it again with the same fixes does nothing.
    @MainActor @discardableResult
    public func configure(_ wanted: MouseFixes) -> Bool {
        let (current, running) = lock.withLock { (fixes, tap != nil) }
        if wanted == current && running == wanted.any { return true }
        stop()
        updateObservers(sideButtons: wanted.sideButtons)
        lock.withLock { fixes = wanted }
        return wanted.any ? start(wanted) : true
    }

    private func start(_ fixes: MouseFixes) -> Bool {
        var mask: CGEventMask = 0
        if fixes.classicWheel { mask |= 1 << CGEventType.scrollWheel.rawValue }
        if fixes.sideButtons {
            mask |= 1 << CGEventType.otherMouseDown.rawValue
            mask |= 1 << CGEventType.otherMouseUp.rawValue
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        // CF objects are thread-safe; the thread only hands its run loop back.
        nonisolated(unsafe) let unsafeSource = source
        nonisolated(unsafe) var started: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            started = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), unsafeSource, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MouseTap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 128 * 1024
        thread.start()
        ready.wait()
        lock.withLock {
            self.tap = tap
            self.runLoop = started
        }
        return true
    }

    private func stop() {
        let (tap, runLoop) = lock.withLock {
            defer { self.tap = nil; self.runLoop = nil }
            return (self.tap, self.runLoop)
        }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: Side buttons state, kept current by notifications

    @MainActor
    private func updateObservers(sideButtons: Bool) {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        guard sideButtons else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let navigates = Self.navigates(app?.bundleIdentifier)
            self?.lock.withLock { self?.frontmostNavigates = navigates }
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readKeyboardLayout() }
        }))
        let navigates = Self.navigates(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        lock.withLock { frontmostNavigates = navigates }
        readKeyboardLayout()
    }

    /// The keys that type [ and ] with ⌘ held, which move on some layouts.
    @MainActor
    private func readKeyboardLayout() {
        let back = CGKeyCode(KeyboardLayout.commandKeyCode(for: "[", fallback: 33))
        let forward = CGKeyCode(KeyboardLayout.commandKeyCode(for: "]", fallback: 30))
        lock.withLock {
            backKey = back
            forwardKey = forward
        }
    }

    // MARK: Tap thread

    /// macOS turns a tap off if it is ever too slow, and after secure input.
    fileprivate func reenable() {
        if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handleScroll(_ event: CGEvent) {
        if naturalScrollingIsOn() { Self.flipIfWheel(event) }
    }

    /// Returns `true` when the event was consumed.
    fileprivate func handleButton(_ event: CGEvent, down: Bool) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == Self.backButton || button == Self.forwardButton else { return false }
        // The release goes wherever its press went, even if the app changed in between.
        if !down { return swallowedButtons.remove(button) != nil }
        let (navigates, key) = lock.withLock {
            (frontmostNavigates, button == Self.backButton ? backKey : forwardKey)
        }
        guard navigates else { return false }
        swallowedButtons.insert(button)
        Self.postCommand(key)
        return true
    }

    /// With natural scrolling off, the wheel already scrolls the classic way.
    /// Read at most once a second; CFPreferences sees changes live.
    private func naturalScrollingIsOn() -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now &- checkedAt > 1_000_000_000 {
            checkedAt = now
            let value = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication)
            naturalScrolling = (value as? Bool) ?? true
        }
        return naturalScrolling
    }

    /// Flags are set explicitly so a held ⇧ or ⌥ can't turn ⌘[ into another shortcut.
    private static func postCommand(_ key: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        // 0x08 is the device bit for the left ⌘ key, which some apps check.
        let flags: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Flips a wheel event in place and leaves trackpad events alone.
    /// Order matters: setting the line delta recomputes the point delta with
    /// acceleration, so the point delta is written last, from its original value.
    @discardableResult
    public static func flipIfWheel(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return false }
        let delta = (event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let fixed = (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let point = (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta.1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed.1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point.0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point.1)
        return true
    }
}

private func mouseTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .scrollWheel:
        tap.handleScroll(event)
    case .otherMouseDown, .otherMouseUp:
        if tap.handleButton(event, down: type == .otherMouseDown) { return nil }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tap.reenable()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
