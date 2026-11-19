import AppKit
import ClipCore
import Darwin

/// Polls `changeCount`, which reveals no content, and reads the pasteboard only
/// when it moves. macOS offers no change notification, so polling is required.
@MainActor
public final class ClipboardMonitor {
    /// Receives a clip, plus the directory holding its staged payloads.
    public typealias Sink = @Sendable (CapturedClip, URL?) -> Void

    private nonisolated static let firstReadDelay = 30
    private nonisolated static let retryDelay = 150
    private nonisolated static let maxRetries = 3

    private let preferences: Preferences
    private let stagingDirectory: URL
    private let sink: Sink
    private var timer: DispatchSourceTimer?
    private var scheduledInterval = 0
    private var lastChange = 0
    // `.workItem` drains autoreleased pasteboard data right after each capture.
    private let queue = DispatchQueue(
        label: "com.mateoduran.smartclipboard.capture", qos: .utility, autoreleaseFrequency: .workItem
    )

    public init(preferences: Preferences, stagingDirectory: URL, sink: @escaping Sink) {
        self.preferences = preferences
        self.stagingDirectory = stagingDirectory
        self.sink = sink
    }

    public func start() {
        lastChange = NSPasteboard.general.changeCount
        reschedule()
    }

    /// Applies a changed check interval; does nothing when it is unchanged.
    public func reschedule() {
        let interval = max(100, preferences.checkIntervalMs)
        guard interval != scheduledInterval else { return }
        scheduledInterval = interval
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        // The leeway lets macOS batch this wakeup with others, which keeps idle CPU near zero.
        source.schedule(
            deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval),
            leeway: .milliseconds(interval / 5)
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }

    /// Keeps a paste from being recorded as a fresh copy.
    public func noteOwnWrite(changeCount: Int) {
        lastChange = changeCount
    }

    private func tick() {
        let change = NSPasteboard.general.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard !preferences.paused else { return }
        Self.capture(
            on: queue, change: change, app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            options: preferences.captureOptions, staging: stagingDirectory, sink: sink, attempt: 0
        )
    }

    /// A writer calls `clearContents`, which bumps the count, and then writes.
    /// A read in between sees nothing, and the count will not move again, so an
    /// empty read is retried: without this, 3 of 60 large copies were lost.
    ///
    /// `nonisolated` so the closure does not inherit main-actor isolation,
    /// which would trap at runtime on this background queue.
    private nonisolated static func capture(
        on queue: DispatchQueue, change: Int, app: String?, options: CaptureOptions, staging: URL,
        sink: @escaping Sink, attempt: Int
    ) {
        let delay = attempt == 0 ? firstReadDelay : retryDelay
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
            let outcome = autoreleasepool {
                let directory = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let outcome = Helper.capture(change: change, app: app, options: options, directory: directory)
                if case .clip(let clip) = outcome { sink(clip, directory) }
                return outcome
            }
            if case .skipped(.empty) = outcome, attempt < maxRetries {
                capture(
                    on: queue, change: change, app: app, options: options, staging: staging,
                    sink: sink, attempt: attempt + 1
                )
            }
            releaseFreeMemory()
        }
    }
}

/// Hands freed heap pages back to the system, so a big copy does not stay in the footprint.
public func releaseFreeMemory() {
    malloc_zone_pressure_relief(nil, 0)
}
