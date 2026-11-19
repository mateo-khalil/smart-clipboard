import ClipCore
import Foundation

public struct MaccyImportResult: Sendable, Equatable {
    public var imported: Int
    public var skipped: Int
}

extension Store {
    public static var maccyDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite")
    }

    /// Works on a temporary copy, so Maccy's own files are never opened for writing.
    /// Inner joins skip the orphan rows Maccy leaves behind in its content table.
    public func importMaccy(
        from source: URL = Store.maccyDatabaseURL,
        retention: RetentionPolicy,
        options: CaptureOptions,
        now: Date = Date()
    ) throws -> MaccyImportResult {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("smartclipboard-import-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let copy = temporary.appendingPathComponent("Storage.sqlite")
        try manager.copyItem(at: source, to: copy)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if manager.fileExists(atPath: wal.path) {
            try manager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }

        let database = try Database(path: copy.path)
        let items = try database.statement("""
        SELECT Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZNUMBEROFCOPIES, ZAPPLICATION, ZPIN FROM ZHISTORYITEM
        ORDER BY ZLASTCOPIEDAT
        """)
        let wanted = (KnownTypes.imagePriority + [KnownTypes.text, KnownTypes.rtf, KnownTypes.html, KnownTypes.fileURL])
            .map { "'\($0)'" }.joined(separator: ",")
        let contents = try database.statement("""
        SELECT c.ZTYPE, CASE WHEN c.ZTYPE IN (\(wanted)) THEN c.ZVALUE END
        FROM ZHISTORYITEMCONTENT c JOIN ZHISTORYITEM i ON c.ZITEM=i.Z_PK WHERE i.Z_PK=?1
        """)

        var result = MaccyImportResult(imported: 0, skipped: 0)
        while try items.step() {
            let firstCopied = Date(timeIntervalSinceReferenceDate: items.double(1))
            let lastCopied = Date(timeIntervalSinceReferenceDate: items.double(2))
            let pin = items.string(5)
            if let days = retention.maxAgeDays, pin == nil,
               lastCopied < now.addingTimeInterval(-Double(days) * 86_400) {
                result.skipped += 1
                continue
            }

            // Repeated types mean a multi-item copy, so each occurrence is one item.
            var pasteboardItems: [[String: Data]] = []
            var extraTypes: [String] = []
            contents.bind(1, items.int(0))
            while try contents.step() {
                let type = contents.string(0) ?? ""
                guard let data = contents.data(1), !data.isEmpty else {
                    extraTypes.append(type)
                    continue
                }
                if let index = pasteboardItems.firstIndex(where: { $0[type] == nil }) {
                    pasteboardItems[index][type] = data
                } else {
                    pasteboardItems.append([type: data])
                }
            }
            contents.reset()

            let replay = ReplaySource(items: pasteboardItems, extraTypes: extraTypes)
            guard case .clip(var clip) = CapturePipeline.capture(
                from: replay, frontmostApp: items.string(4), now: lastCopied, options: options
            ) else {
                result.skipped += 1
                continue
            }
            clip.firstCopied = firstCopied
            clip.lastCopied = lastCopied
            clip.copyCount = max(1, Int(items.int(3)))
            clip.pinKey = pin
            try insert(clip)
            result.imported += 1
        }
        return result
    }
}
