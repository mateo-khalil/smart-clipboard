import ClipCore
import Foundation

public struct StoreStats: Sendable, Equatable {
    public var items: Int
    public var pinned: Int
    public var diskBytes: Int64
}

public struct PurgeResult: Sendable, Equatable {
    public var removed: Int
}

/// The history lives here, on disk; nothing keeps it in memory.
/// Writes and reads each own a confined connection, and blocking work stays on
/// these serial queues so the main thread only ever waits for short lookups.
public final class Store: @unchecked Sendable {
    static let inlineLimit = CapturedClip.inlineLimit
    static let purgeBatch = 200

    public let directory: URL
    let files: PayloadFiles
    /// Where the helper writes large payloads, on the same volume as `payloads`.
    public let stagingDirectory: URL
    let databasePath: String
    let writer: Database
    let reader: Database
    let writeQueue = DispatchQueue(label: "com.mateoduran.smartclipboard.store.write", qos: .utility)
    let readQueue = DispatchQueue(label: "com.mateoduran.smartclipboard.store.read", qos: .userInitiated)

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartClipboard", isDirectory: true)
    }

    public init(directory: URL = Store.defaultDirectory) throws {
        self.directory = directory
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let payloads = directory.appendingPathComponent("payloads", isDirectory: true)
        try manager.createDirectory(at: payloads, withIntermediateDirectories: true)
        files = PayloadFiles(root: payloads)
        stagingDirectory = directory.appendingPathComponent("staging", isDirectory: true)
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("history.sqlite").path

        writer = try Database(path: databasePath)
        try Self.configure(writer, cacheKiB: 512)
        try Self.migrate(writer)
        reader = try Database(path: databasePath)
        try Self.configure(reader, cacheKiB: 256)
        try reader.execute("PRAGMA query_only=ON")
    }

    /// The default cache reaches about 8 MB per connection, hence the explicit size.
    /// `auto_vacuum` goes first: once WAL writes the header, SQLite silently ignores it.
    private static func configure(_ database: Database, cacheKiB: Int) throws {
        try database.execute("""
        PRAGMA auto_vacuum=INCREMENTAL;
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=ON;
        PRAGMA cache_size=-\(cacheKiB);
        PRAGMA mmap_size=0;
        PRAGMA temp_store=FILE;
        PRAGMA wal_autocheckpoint=256;
        PRAGMA journal_size_limit=1048576;
        """)
    }

    private static func migrate(_ database: Database) throws {
        guard try database.scalarInt("PRAGMA user_version") == 0 else { return }
        try database.transaction {
            try database.execute("""
            CREATE TABLE items(
                id INTEGER PRIMARY KEY,
                kind INTEGER NOT NULL,
                title TEXT NOT NULL,
                color INTEGER,
                hash BLOB NOT NULL UNIQUE,
                source_app TEXT,
                first_copied REAL NOT NULL,
                last_copied REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1,
                pin TEXT UNIQUE,
                byte_size INTEGER NOT NULL,
                thumb_w INTEGER NOT NULL DEFAULT 0,
                thumb_h INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX items_last ON items(last_copied DESC, id DESC);
            CREATE INDEX items_first ON items(first_copied DESC, id DESC);
            CREATE INDEX items_count ON items(copy_count DESC, id DESC);

            -- Side tables keep listing and paging from touching text or images.
            CREATE TABLE search(
                item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                normalized TEXT NOT NULL,
                raw TEXT NOT NULL
            );
            CREATE TABLE thumbs(
                item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                data BLOB NOT NULL
            );
            CREATE TABLE reps(
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                uti TEXT NOT NULL,
                item_index INTEGER NOT NULL,
                inline_data BLOB,
                file TEXT,
                size INTEGER NOT NULL,
                PRIMARY KEY(item_id, uti, item_index)
            ) WITHOUT ROWID;
            CREATE INDEX reps_file ON reps(file) WHERE file IS NOT NULL;
            PRAGMA user_version=1;
            """)
        }
    }

    // MARK: Writing

    /// Stores a copy, or moves the existing identical item to the top.
    @discardableResult
    public func insert(_ clip: CapturedClip, stagedIn staging: URL? = nil) throws -> Int64 {
        try writeQueue.sync {
            let existing = try writer.statement("SELECT id FROM items WHERE hash=?1")
            existing.bind(1, clip.hash)
            if try existing.step() {
                let id = existing.int(0)
                let update = try writer.statement("""
                UPDATE items SET last_copied=MAX(last_copied, ?1), copy_count=copy_count+?2, source_app=COALESCE(?3, source_app)
                WHERE id=?4
                """)
                update.bind(1, clip.lastCopied.timeIntervalSince1970)
                update.bind(2, Int64(clip.copyCount))
                update.bind(3, clip.sourceApp)
                update.bind(4, id)
                try update.run()
                return id
            }

            // Files go first: a crash here leaves an orphan, never a row without data.
            var stored: [(ClipRepresentation, String?)] = []
            for representation in clip.representations {
                let name: String?
                if let file = representation.staged, let staging {
                    name = try files.adopt(staging.appendingPathComponent(file.digest), digest: file.digest)
                } else {
                    name = representation.data.count > Self.inlineLimit ? try files.store(representation.data) : nil
                }
                stored.append((representation, name))
            }
            let total = clip.representations.reduce(Int64(0)) { $0 + Int64($1.byteCount) }

            return try writer.transaction {
                let insert = try writer.statement("""
                INSERT INTO items(kind, title, color, hash, source_app, first_copied, last_copied, copy_count, pin,
                                  byte_size, thumb_w, thumb_h)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                """)
                insert.bind(1, Int64(clip.kind.rawValue))
                insert.bind(2, clip.title)
                insert.bind(3, clip.color.map(Int64.init))
                insert.bind(4, clip.hash)
                insert.bind(5, clip.sourceApp)
                insert.bind(6, clip.firstCopied.timeIntervalSince1970)
                insert.bind(7, clip.lastCopied.timeIntervalSince1970)
                insert.bind(8, Int64(clip.copyCount))
                insert.bind(9, clip.pinKey)
                insert.bind(10, total)
                insert.bind(11, Int64(clip.thumbnail?.width ?? 0))
                insert.bind(12, Int64(clip.thumbnail?.height ?? 0))
                try insert.run()
                let id = writer.lastInsertID

                let search = try writer.statement("INSERT INTO search(item_id, normalized, raw) VALUES(?1, ?2, ?3)")
                search.bind(1, id)
                search.bind(2, clip.searchNormalized)
                search.bind(3, clip.searchRaw)
                try search.run()

                if let thumbnail = clip.thumbnail {
                    let thumb = try writer.statement("INSERT INTO thumbs(item_id, data) VALUES(?1, ?2)")
                    thumb.bind(1, id)
                    thumb.bind(2, thumbnail.data)
                    try thumb.run()
                }

                let rep = try writer.statement("""
                INSERT INTO reps(item_id, uti, item_index, inline_data, file, size) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                """)
                for (representation, name) in stored {
                    rep.bind(1, id)
                    rep.bind(2, representation.uti)
                    rep.bind(3, Int64(representation.itemIndex))
                    rep.bind(4, name == nil ? representation.data : nil)
                    rep.bind(5, name)
                    rep.bind(6, Int64(representation.byteCount))
                    try rep.run()
                }
                return id
            }
        }
    }

    /// Selecting an item counts as copying it again, which also renews its 30 days.
    public func touch(id: Int64, now: Date = Date()) throws {
        try writeQueue.sync {
            let update = try writer.statement("UPDATE items SET last_copied=?1, copy_count=copy_count+1 WHERE id=?2")
            update.bind(1, now.timeIntervalSince1970)
            update.bind(2, id)
            try update.run()
        }
    }

    public func setPin(id: Int64, key: String?) throws {
        try writeQueue.sync {
            let update = try writer.statement("UPDATE items SET pin=?1 WHERE id=?2")
            update.bind(1, key)
            update.bind(2, id)
            try update.run()
        }
    }

    public func delete(id: Int64) throws {
        try writeQueue.sync { try deleteItems([id]) }
    }

    /// Pins survive unless `includingPins` is set.
    public func clearAll(includingPins: Bool = false) throws {
        try writeQueue.sync {
            let filter = includingPins ? "" : "WHERE pin IS NULL"
            var ids: [Int64] = []
            let query = try writer.statement("SELECT id FROM items \(filter)")
            while try query.step() { ids.append(query.int(0)) }
            try deleteItems(ids)
            try reclaimSpace()
        }
    }

    /// Runs on `writeQueue`. Deletes rows first, then any file left unreferenced.
    func deleteItems(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        var candidates: Set<String> = []
        try writer.transaction {
            let selectFiles = try writer.statement("SELECT file FROM reps WHERE item_id=?1 AND file IS NOT NULL")
            let remove = try writer.statement("DELETE FROM items WHERE id=?1")
            for id in ids {
                selectFiles.bind(1, id)
                while try selectFiles.step() {
                    if let file = selectFiles.string(0) { candidates.insert(file) }
                }
                selectFiles.reset()
                remove.bind(1, id)
                try remove.run()
            }
        }
        let stillUsed = try writer.statement("SELECT 1 FROM reps WHERE file=?1 LIMIT 1")
        for file in candidates {
            stillUsed.bind(1, file)
            let used = try stillUsed.step()
            stillUsed.reset()
            if !used { files.remove(file) }
        }
    }

    func reclaimSpace() throws {
        try writer.execute("PRAGMA incremental_vacuum")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: Retention

    /// Expires old items, then enforces the item and disk caps oldest-first.
    /// Each batch releases the queue, so the panel never waits for a long purge.
    public func purge(policy: RetentionPolicy, now: Date = Date()) throws -> PurgeResult {
        var removed = 0
        if let days = policy.maxAgeDays {
            let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
            removed += try purgeLoop { database in
                let query = try database.statement("""
                SELECT id FROM items WHERE +pin IS NULL AND last_copied < ?1 ORDER BY last_copied LIMIT ?2
                """)
                query.bind(1, cutoff)
                query.bind(2, Int64(Self.purgeBatch))
                return try Self.ids(from: query)
            }
        }
        removed += try purgeLoop { database in
            let excess = try database.scalarInt("SELECT COUNT(*) FROM items") - Int64(policy.maxItems)
            guard excess > 0 else { return [] }
            return try Self.oldestUnpinned(database, limit: min(excess, Int64(Self.purgeBatch)))
        }
        removed += try purgeLoop { database in
            var excess = try database.scalarInt("SELECT COALESCE(SUM(byte_size), 0) FROM items") - policy.maxBytes
            guard excess > 0 else { return [] }
            // Takes only as many items as the excess requires, never a fixed amount.
            let query = try database.statement("""
            SELECT id, byte_size FROM items WHERE +pin IS NULL ORDER BY last_copied LIMIT ?1
            """)
            query.bind(1, Int64(Self.purgeBatch))
            var ids: [Int64] = []
            while excess > 0, try query.step() {
                ids.append(query.int(0))
                excess -= query.int(1)
            }
            return ids
        }
        if removed > 0 { try writeQueue.sync { try reclaimSpace() } }
        return PurgeResult(removed: removed)
    }

    private func purgeLoop(select: (Database) throws -> [Int64]) throws -> Int {
        var removed = 0
        while true {
            // A pool per batch: temporary objects would otherwise pile up across a long purge.
            let count = try autoreleasepool {
                try writeQueue.sync { () throws -> Int in
                    let ids = try select(writer)
                    try deleteItems(ids)
                    return ids.count
                }
            }
            removed += count
            if count == 0 { return removed }
        }
    }

    private static func oldestUnpinned(_ database: Database, limit: Int64) throws -> [Int64] {
        let query = try database.statement("SELECT id FROM items WHERE +pin IS NULL ORDER BY last_copied LIMIT ?1")
        query.bind(1, limit)
        return try ids(from: query)
    }

    private static func ids(from query: Statement) throws -> [Int64] {
        var ids: [Int64] = []
        while try query.step() { ids.append(query.int(0)) }
        return ids
    }

    /// Removes files no row references, left behind by a crash between the two writes.
    @discardableResult
    public func sweepOrphans() throws -> Int {
        try writeQueue.sync {
            var referenced: Set<String> = []
            let query = try writer.statement("SELECT DISTINCT file FROM reps WHERE file IS NOT NULL")
            while try query.step() {
                if let file = query.string(0) { referenced.insert(file) }
            }
            let manager = FileManager.default
            for leftover in (try? manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [] {
                try? manager.removeItem(at: leftover)
            }
            return files.removeLeftovers(keeping: referenced)
        }
    }

    // MARK: Reading

    static let rowColumns = """
    i.id, i.kind, i.title, i.color, i.thumb_w, i.thumb_h, i.pin, i.source_app,
    i.first_copied, i.last_copied, i.copy_count, i.byte_size
    """

    static func row(from query: Statement) -> ClipRow {
        ClipRow(
            id: query.int(0),
            kind: ClipKind(rawValue: Int(query.int(1))) ?? .text,
            title: query.string(2) ?? "",
            color: query.isNull(3) ? nil : UInt32(truncatingIfNeeded: query.int(3)),
            thumbWidth: Int(query.int(4)),
            thumbHeight: Int(query.int(5)),
            pinKey: query.string(6),
            sourceApp: query.string(7),
            firstCopied: Date(timeIntervalSince1970: query.double(8)),
            lastCopied: Date(timeIntervalSince1970: query.double(9)),
            copyCount: Int(query.int(10)),
            byteSize: query.int(11)
        )
    }

    static func column(for sort: HistorySort) -> String {
        switch sort {
        case .lastCopy: return "last_copied"
        case .firstCopy: return "first_copied"
        case .copyCount: return "copy_count"
        }
    }

    /// Keyset paging: unlike OFFSET, the cost does not grow with scroll depth.
    public func page(sort: HistorySort, after cursor: PageCursor? = nil, limit: Int) -> [ClipRow] {
        readQueue.sync {
            do {
                let key = Self.column(for: sort)
                let bound = cursor == nil ? "" : "AND (i.\(key), i.id) < (?2, ?3)"
                let query = try reader.statement("""
                SELECT \(Self.rowColumns) FROM items i WHERE +i.pin IS NULL \(bound)
                ORDER BY i.\(key) DESC, i.id DESC LIMIT ?1
                """)
                query.bind(1, Int64(limit))
                if let cursor {
                    query.bind(2, cursor.key)
                    query.bind(3, cursor.id)
                }
                var rows: [ClipRow] = []
                while try query.step() { rows.append(Self.row(from: query)) }
                return rows
            } catch {
                return []
            }
        }
    }

    public static func cursor(after row: ClipRow, sort: HistorySort) -> PageCursor {
        switch sort {
        case .lastCopy: return PageCursor(key: row.lastCopied.timeIntervalSince1970, id: row.id)
        case .firstCopy: return PageCursor(key: row.firstCopied.timeIntervalSince1970, id: row.id)
        case .copyCount: return PageCursor(key: Double(row.copyCount), id: row.id)
        }
    }

    public func pinned() -> [ClipRow] {
        readQueue.sync {
            guard let query = try? reader.statement("""
            SELECT \(Self.rowColumns) FROM items i WHERE i.pin IS NOT NULL ORDER BY i.pin
            """) else { return [] }
            var rows: [ClipRow] = []
            while (try? query.step()) == true { rows.append(Self.row(from: query)) }
            return rows
        }
    }

    public func rows(ids: [Int64]) -> [ClipRow] {
        guard !ids.isEmpty else { return [] }
        return readQueue.sync {
            guard let query = try? reader.statement("SELECT \(Self.rowColumns) FROM items i WHERE i.id=?1") else { return [] }
            var rows: [ClipRow] = []
            rows.reserveCapacity(ids.count)
            for id in ids {
                query.bind(1, id)
                if (try? query.step()) == true { rows.append(Self.row(from: query)) }
                query.reset()
            }
            return rows
        }
    }

    public func thumbnail(id: Int64) -> Data? {
        readQueue.sync {
            guard let query = try? reader.statement("SELECT data FROM thumbs WHERE item_id=?1") else { return nil }
            query.bind(1, id)
            return (try? query.step()) == true ? query.data(0) : nil
        }
    }

    public func searchText(id: Int64) -> String? {
        readQueue.sync {
            guard let query = try? reader.statement("SELECT raw FROM search WHERE item_id=?1") else { return nil }
            query.bind(1, id)
            return (try? query.step()) == true ? query.string(0) : nil
        }
    }

    /// Inline payloads are copied; file payloads stay mapped until released.
    public func representations(id: Int64) throws -> [ClipRepresentation] {
        try readQueue.sync {
            let query = try reader.statement("""
            SELECT uti, item_index, inline_data, file FROM reps WHERE item_id=?1 ORDER BY item_index, uti
            """)
            query.bind(1, id)
            var result: [ClipRepresentation] = []
            while try query.step() {
                let data = try query.string(3).map(files.load) ?? query.data(2) ?? Data()
                result.append(ClipRepresentation(uti: query.string(0) ?? "", itemIndex: Int(query.int(1)), data: data))
            }
            return result
        }
    }

    /// Describes an item for the helper, by path, without reading any payload.
    public func pasteEntries(id: Int64) throws -> [PasteEntry] {
        try readQueue.sync {
            let query = try reader.statement("""
            SELECT uti, item_index, inline_data, file FROM reps WHERE item_id=?1 ORDER BY item_index, uti
            """)
            query.bind(1, id)
            var entries: [PasteEntry] = []
            while try query.step() {
                entries.append(PasteEntry(
                    uti: query.string(0) ?? "", itemIndex: Int(query.int(1)),
                    inlineData: query.string(3) == nil ? query.data(2) : nil,
                    path: query.string(3).map(files.path(of:))
                ))
            }
            return entries
        }
    }

    public func stats() -> StoreStats {
        readQueue.sync {
            let items = (try? reader.scalarInt("SELECT COUNT(*) FROM items")) ?? 0
            let pinned = (try? reader.scalarInt("SELECT COUNT(*) FROM items WHERE pin IS NOT NULL")) ?? 0
            let payload = (try? reader.scalarInt("""
            SELECT COALESCE(SUM(size), 0) FROM (SELECT DISTINCT file, size FROM reps WHERE file IS NOT NULL)
            """)) ?? 0
            let manager = FileManager.default
            let database = [databasePath, databasePath + "-wal"].reduce(Int64(0)) { sum, path in
                let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                return sum + size
            }
            return StoreStats(items: Int(items), pinned: Int(pinned), diskBytes: payload + database)
        }
    }
}
