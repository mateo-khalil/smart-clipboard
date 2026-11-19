import ClipCore
import Darwin
import Foundation

/// Runs `cliphelper`, which touches clipboard data in its own short-lived process.
///
/// Measured: reading one 17 MiB image left this process with a live 17.2 MB
/// CFData held by NSPasteboard, plus a freed block of the same size kept by the
/// allocator, 34 MB in all. Neither can be released from here, so the bytes never
/// come here. When the helper exits, all of it goes with it, and a malformed
/// copy can only crash the helper.
///
/// These calls block, so none of them may run on the main thread.
public enum Helper {
    private static let executable = Bundle.main.url(forAuxiliaryExecutable: "cliphelper")?.path

    public static var isAvailable: Bool { executable != nil }

    /// Without the helper the work happens in process: a partial install costs
    /// memory, not functionality.
    public static func capture(change: Int, app: String?, options: CaptureOptions, directory: URL) -> CaptureOutcome {
        guard let executable, let optionsData = try? JSONEncoder().encode(options) else {
            return CapturePipeline.capture(from: SystemPasteboard(), expectedChange: change, frontmostApp: app, options: options)
        }
        let manager = FileManager.default
        let optionsFile = directory.appendingPathComponent("options.json")
        let resultFile = directory.appendingPathComponent("result.json")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try optionsData.write(to: optionsFile)
        } catch {
            return .skipped(.stale)
        }
        guard spawn(executable, [executable, "capture", directory.path, String(change), app ?? "-"]),
              let data = try? Data(contentsOf: resultFile),
              let outcome = try? JSONDecoder().decode(CaptureOutcome.self, from: data) else {
            return .skipped(.stale)
        }
        return outcome
    }

    /// Writes to the pasteboard from the helper. The pasteboard keeps the data after it exits.
    public static func paste(_ entries: [PasteEntry], plainTextOnly: Bool) -> Bool {
        guard let executable else { return false }
        return withTemporaryDirectory { directory in
            let manifest = directory.appendingPathComponent("paste.json")
            guard let data = try? JSONEncoder().encode(entries), (try? data.write(to: manifest)) != nil else { return false }
            return spawn(executable, [executable, "paste", manifest.path, plainTextOnly ? "plain" : "full"])
        } ?? false
    }

    public static func preview(of data: Data, maxPixelSize: Int) -> Data? {
        guard let executable else { return Thumbnailer.encoded(data, maxPixelSize: maxPixelSize) }
        return withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("input")
            let target = directory.appendingPathComponent("output")
            guard (try? data.write(to: source)) != nil,
                  spawn(executable, [executable, "preview", source.path, target.path, String(maxPixelSize)]) else { return nil }
            return try? Data(contentsOf: target)
        } ?? nil
    }

    /// Small items are written in process, which needs their bytes here.
    public static func representation(from entry: PasteEntry) -> ClipRepresentation? {
        let data = entry.inlineData ?? entry.path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped) }
        return data.map { ClipRepresentation(uti: entry.uti, itemIndex: entry.itemIndex, data: $0) }
    }

    private static func withTemporaryDirectory<T>(_ body: (URL) -> T) -> T? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("smartclipboard-\(UUID().uuidString)", isDirectory: true)
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return nil
        }
        defer { try? manager.removeItem(at: directory) }
        return body(directory)
    }

    private static func spawn(_ path: String, _ arguments: [String]) -> Bool {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, nil, argv, &environment) == 0 else { return false }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return false }
        }
        // WIFEXITED with a zero exit code.
        return status & 0x7F == 0 && (status >> 8) & 0xFF == 0
    }
}
