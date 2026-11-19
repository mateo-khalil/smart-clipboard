import CoreGraphics
import Foundation

/// Makes a mouse wheel scroll the classic way while the trackpad keeps natural
/// scrolling. macOS has a single switch for both, so an event tap flips the
/// wheel's events back. A wheel sends discrete steps and a trackpad (or a Magic
/// Mouse) continuous ones: `isContinuous` tells them apart.
///
/// The tap runs on its own thread. On the main thread, any busy moment of the
/// app would stall scrolling in every app. Idle, the thread sleeps in the
/// kernel: no timer, no polling.
public final class ScrollReverser: @unchecked Sendable {
    public static let shared = ScrollReverser()

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    // Touched only on the tap thread.
    private var naturalScrolling = true
    private var checkedAt: UInt64 = 0

    private init() {}

    public var isRunning: Bool { lock.withLock { tap != nil } }

    /// Returns `false` when the tap cannot be created, which means the app
    /// lacks Accessibility. Calling it again with the same value does nothing.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? start() : stop()
    }

    private func start() -> Bool {
        if isRunning { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: scrollTapCallback,
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
        thread.name = "ScrollReverser"
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

    private func stop() -> Bool {
        let (tap, runLoop) = lock.withLock {
            defer { self.tap = nil; self.runLoop = nil }
            return (self.tap, self.runLoop)
        }
        guard let tap else { return true }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        return true
    }

    /// macOS turns a tap off if it is ever too slow, and after secure input.
    fileprivate func reenable() {
        if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// With natural scrolling off, the wheel already scrolls the classic way.
    /// Read at most once a second; CFPreferences sees changes live.
    fileprivate func naturalScrollingIsOn() -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now &- checkedAt > 1_000_000_000 {
            checkedAt = now
            let value = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication)
            naturalScrolling = (value as? Bool) ?? true
        }
        return naturalScrolling
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

private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let reverser = Unmanaged<ScrollReverser>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .scrollWheel:
        if reverser.naturalScrollingIsOn() { ScrollReverser.flipIfWheel(event) }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        reverser.reenable()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
