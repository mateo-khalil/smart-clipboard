import ClipCore
import Foundation

/// Content-addressed files, so identical payloads share one copy on disk.
struct PayloadFiles {
    let root: URL

    private func url(for name: String) -> URL {
        root.appendingPathComponent(String(name.prefix(2)), isDirectory: true).appendingPathComponent(name)
    }

    /// Writes through a temporary file: a crash can leave an orphan, never a torn payload.
    func store(_ data: Data) throws -> String {
        let name = ContentDigest.hex(of: data)
        let target = url(for: name)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { return name }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.appendingPathExtension("tmp")
        try data.write(to: temporary)
        do {
            try manager.moveItem(at: temporary, to: target)
        } catch {
            try? manager.removeItem(at: temporary)
            if !manager.fileExists(atPath: target.path) { throw error }
        }
        return name
    }

    /// Takes over a file the helper already wrote, without reading it.
    func adopt(_ staged: URL, digest: String) throws -> String {
        let target = url(for: digest)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { return digest }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staged, to: target)
        return digest
    }

    func path(of name: String) -> String { url(for: name).path }

    /// Mapped, not copied, so a large paste adds no heap memory.
    func load(_ name: String) throws -> Data {
        try Data(contentsOf: url(for: name), options: .alwaysMapped)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    func allNames() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(url.lastPathComponent)
            }
        }
        return names
    }

    func removeLeftovers(keeping referenced: Set<String>) -> Int {
        var removed = 0
        for name in allNames() where !referenced.contains(name) {
            if name.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: url(for: String(name.dropLast(4))).appendingPathExtension("tmp"))
            } else {
                remove(name)
            }
            removed += 1
        }
        return removed
    }
}
