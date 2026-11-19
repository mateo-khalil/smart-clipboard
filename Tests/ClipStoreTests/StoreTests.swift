import ClipCore
import CryptoKit
import Foundation
import Testing
@testable import ClipStore

private final class TemporaryStore {
    let directory: URL
    let store: Store

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstore-\(UUID().uuidString)")
        store = try Store(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var payloadCount: Int { store.files.allNames().count }
}

private func makeClip(
    _ text: String, at date: Date = Date(), payload: Data? = nil, kind: ClipKind = .text, pin: String? = nil
) -> CapturedClip {
    let data = payload ?? Data(text.utf8)
    return CapturedClip(
        kind: kind, title: text, color: nil, searchRaw: text, searchNormalized: TextTools.normalize(text),
        representations: [ClipRepresentation(uti: KnownTypes.text, itemIndex: 0, data: data)],
        thumbnail: nil, sourceApp: "com.test", hash: Data(SHA256.hash(data: data)),
        firstCopied: date, lastCopied: date, pinKey: pin
    )
}

private let day: TimeInterval = 86_400

@Suite struct StoreTests {
    @Test func insertThenListNewestFirst() throws {
        let t = try TemporaryStore()
        let now = Date()
        try t.store.insert(makeClip("old", at: now.addingTimeInterval(-10)))
        try t.store.insert(makeClip("new", at: now))
        #expect(t.store.page(sort: .lastCopy, limit: 10).map(\.title) == ["new", "old"])
    }

    @Test func recopyingMovesToTopWithoutDuplicating() throws {
        let t = try TemporaryStore()
        let now = Date()
        let first = try t.store.insert(makeClip("a", at: now.addingTimeInterval(-10)))
        try t.store.insert(makeClip("b", at: now.addingTimeInterval(-5)))
        let again = try t.store.insert(makeClip("a", at: now))
        #expect(first == again)
        let rows = t.store.page(sort: .lastCopy, limit: 10)
        #expect(rows.map(\.title) == ["a", "b"])
        #expect(rows[0].copyCount == 2)
        #expect(t.store.stats().items == 2)
    }

    @Test func keysetPagingWalksEverythingOnce() throws {
        let t = try TemporaryStore()
        let base = Date()
        for index in 0..<25 { try t.store.insert(makeClip("item \(index)", at: base.addingTimeInterval(Double(index)))) }
        var seen: [String] = []
        var cursor: PageCursor?
        while true {
            let page = t.store.page(sort: .lastCopy, after: cursor, limit: 10)
            if page.isEmpty { break }
            seen += page.map(\.title)
            cursor = Store.cursor(after: page[page.count - 1], sort: .lastCopy)
        }
        #expect(seen.count == 25)
        #expect(seen.first == "item 24")
        #expect(Set(seen).count == 25)
    }

    @Test func pagingHandlesTiedSortKeys() throws {
        let t = try TemporaryStore()
        let same = Date()
        for index in 0..<7 { try t.store.insert(makeClip("tie \(index)", at: same)) }
        let first = t.store.page(sort: .copyCount, limit: 3)
        let cursor = Store.cursor(after: first[2], sort: .copyCount)
        let second = t.store.page(sort: .copyCount, after: cursor, limit: 10)
        #expect(Set((first + second).map(\.id)).count == 7)
    }

    @Test func smallPayloadsStayInlineAndLargeOnesGoToFiles() throws {
        let t = try TemporaryStore()
        let small = try t.store.insert(makeClip("small"))
        #expect(t.payloadCount == 0)
        let big = Data(repeating: 7, count: Store.inlineLimit + 1)
        let large = try t.store.insert(makeClip("large", payload: big))
        #expect(t.payloadCount == 1)
        #expect(try t.store.representations(id: small)[0].data == Data("small".utf8))
        #expect(try t.store.representations(id: large)[0].data == big)
    }

    @Test func multiItemCopiesRestoreInOrder() throws {
        let t = try TemporaryStore()
        var clip = makeClip("two files")
        clip.representations = [
            ClipRepresentation(uti: KnownTypes.fileURL, itemIndex: 1, data: Data("b".utf8)),
            ClipRepresentation(uti: KnownTypes.fileURL, itemIndex: 0, data: Data("a".utf8)),
        ]
        let id = try t.store.insert(clip)
        #expect(try t.store.representations(id: id).map(\.itemIndex) == [0, 1])
    }

    @Test func deletingRemovesFilesOnlyWhenUnreferenced() throws {
        let t = try TemporaryStore()
        let shared = Data(repeating: 9, count: Store.inlineLimit + 1)
        var a = makeClip("a", payload: shared)
        a.hash = Data([1])
        var b = makeClip("b", payload: shared)
        b.hash = Data([2])
        let first = try t.store.insert(a)
        let second = try t.store.insert(b)
        #expect(t.payloadCount == 1)
        try t.store.delete(id: first)
        #expect(t.payloadCount == 1)
        #expect(try t.store.representations(id: second)[0].data == shared)
        try t.store.delete(id: second)
        #expect(t.payloadCount == 0)
    }

    @Test func clearAllKeepsPinsAndFreesDisk() throws {
        let t = try TemporaryStore()
        let keep = try t.store.insert(makeClip("keep", payload: Data(repeating: 1, count: Store.inlineLimit + 1)))
        try t.store.setPin(id: keep, key: "b")
        for index in 0..<50 {
            try t.store.insert(makeClip("gone \(index)", payload: Data(repeating: UInt8(index), count: Store.inlineLimit + 1)))
        }
        let before = t.store.stats().diskBytes
        try t.store.clearAll()
        let stats = t.store.stats()
        #expect(stats.items == 1)
        #expect(stats.pinned == 1)
        #expect(t.payloadCount == 1)
        #expect(stats.diskBytes < before)
    }

    @Test func clearAllShrinksTheDatabaseFile() throws {
        let t = try TemporaryStore()
        let filler = String(repeating: "x", count: 8_000)
        for index in 0..<400 { try t.store.insert(makeClip("\(index) \(filler)")) }
        let path = t.directory.appendingPathComponent("history.sqlite").path
        try t.store.writeQueue.sync { try t.store.writer.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        let full = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        try t.store.clearAll()
        let empty = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        #expect(empty < full / 4)
    }

    @Test func pinsSortIntoTheirOwnList() throws {
        let t = try TemporaryStore()
        let id = try t.store.insert(makeClip("pinned"))
        try t.store.insert(makeClip("plain"))
        try t.store.setPin(id: id, key: "c")
        #expect(t.store.pinned().map(\.title) == ["pinned"])
        #expect(t.store.page(sort: .lastCopy, limit: 10).map(\.title) == ["plain"])
        try t.store.setPin(id: id, key: nil)
        #expect(t.store.pinned().isEmpty)
    }

    @Test func thumbnailsLiveInTheirOwnTable() throws {
        let t = try TemporaryStore()
        var clip = makeClip("image", kind: .image)
        clip.thumbnail = ClipThumbnail(data: Data([1, 2, 3]), width: 30, height: 20)
        let id = try t.store.insert(clip)
        #expect(t.store.thumbnail(id: id) == Data([1, 2, 3]))
        #expect(t.store.page(sort: .lastCopy, limit: 1)[0].thumbHeight == 20)
    }

    @Test func storeReopensWithItsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try Store(directory: directory)
            try store.insert(makeClip("survives"))
        }
        #expect(try Store(directory: directory).page(sort: .lastCopy, limit: 1).map(\.title) == ["survives"])
    }

    @Test func dataDirectoryIsPrivate() throws {
        let t = try TemporaryStore()
        let attributes = try FileManager.default.attributesOfItem(atPath: t.directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

@Suite struct RetentionTests {
    private let policy = RetentionPolicy(maxAgeDays: 30, maxItems: 10_000, maxBytes: 5 * 1_073_741_824)

    @Test func itemsExpireThirtyDaysAfterLastCopy() throws {
        let t = try TemporaryStore()
        let now = Date()
        try t.store.insert(makeClip("expired", at: now.addingTimeInterval(-31 * day)))
        try t.store.insert(makeClip("fresh", at: now.addingTimeInterval(-29 * day)))
        #expect(try t.store.purge(policy: policy, now: now).removed == 1)
        #expect(t.store.page(sort: .lastCopy, limit: 10).map(\.title) == ["fresh"])
    }

    @Test func recopyingRenewsTheThirtyDays() throws {
        let t = try TemporaryStore()
        let now = Date()
        try t.store.insert(makeClip("renewed", at: now.addingTimeInterval(-40 * day)))
        try t.store.insert(makeClip("renewed", at: now.addingTimeInterval(-1 * day)))
        #expect(try t.store.purge(policy: policy, now: now).removed == 0)
    }

    @Test func selectingAnItemRenewsItToo() throws {
        let t = try TemporaryStore()
        let now = Date()
        let id = try t.store.insert(makeClip("used", at: now.addingTimeInterval(-40 * day)))
        try t.store.touch(id: id, now: now)
        #expect(try t.store.purge(policy: policy, now: now).removed == 0)
    }

    @Test func pinsNeverExpire() throws {
        let t = try TemporaryStore()
        let now = Date()
        let id = try t.store.insert(makeClip("pinned", at: now.addingTimeInterval(-400 * day)))
        try t.store.setPin(id: id, key: "b")
        #expect(try t.store.purge(policy: policy, now: now).removed == 0)
    }

    @Test func neverDisablesExpiry() throws {
        let t = try TemporaryStore()
        let now = Date()
        try t.store.insert(makeClip("ancient", at: now.addingTimeInterval(-4000 * day)))
        var forever = policy
        forever.maxAgeDays = nil
        #expect(try t.store.purge(policy: forever, now: now).removed == 0)
    }

    @Test func purgeLeavesNoOrphanFiles() throws {
        let t = try TemporaryStore()
        let now = Date()
        for index in 0..<450 {
            try t.store.insert(makeClip(
                "old \(index)", at: now.addingTimeInterval(-60 * day),
                payload: Data(repeating: UInt8(index % 256), count: Store.inlineLimit + 1 + index)
            ))
        }
        #expect(t.payloadCount == 450)
        #expect(try t.store.purge(policy: policy, now: now).removed == 450)
        #expect(t.payloadCount == 0)
        #expect(t.store.stats().items == 0)
    }

    @Test func itemCapRemovesOldestUnpinned() throws {
        let t = try TemporaryStore()
        let now = Date()
        let pinned = try t.store.insert(makeClip("pinned oldest", at: now.addingTimeInterval(-100)))
        try t.store.setPin(id: pinned, key: "b")
        for index in 0..<5 { try t.store.insert(makeClip("item \(index)", at: now.addingTimeInterval(Double(index)))) }
        let capped = RetentionPolicy(maxAgeDays: nil, maxItems: 3, maxBytes: .max)
        #expect(try t.store.purge(policy: capped, now: now).removed == 3)
        #expect(t.store.page(sort: .lastCopy, limit: 10).map(\.title) == ["item 4", "item 3"])
        #expect(t.store.pinned().count == 1)
    }

    @Test func diskCapRemovesOldestFirst() throws {
        let t = try TemporaryStore()
        let now = Date()
        for index in 0..<30 {
            try t.store.insert(makeClip(
                "item \(index)", at: now.addingTimeInterval(Double(index)),
                payload: Data(repeating: UInt8(index), count: 1_000)
            ))
        }
        let capped = RetentionPolicy(maxAgeDays: nil, maxItems: 1_000, maxBytes: 5_000)
        _ = try t.store.purge(policy: capped, now: now)
        let rows = t.store.page(sort: .lastCopy, limit: 100)
        #expect(rows.reduce(0) { $0 + $1.byteSize } <= 5_000)
        #expect(rows.first?.title == "item 29")
    }

    @Test func sweepRemovesFilesFromInterruptedWrites() throws {
        let t = try TemporaryStore()
        let kept = Data(repeating: 1, count: Store.inlineLimit + 1)
        let id = try t.store.insert(makeClip("kept", payload: kept))
        _ = try t.store.files.store(Data([9, 9, 9]))
        #expect(t.payloadCount == 2)
        #expect(try t.store.sweepOrphans() == 1)
        #expect(t.payloadCount == 1)
        #expect(try t.store.representations(id: id)[0].data == kept)
    }
}

@Suite struct SearchTests {
    private func seeded() throws -> TemporaryStore {
        let t = try TemporaryStore()
        let now = Date()
        for (index, text) in ["sudo launchctl bootout", "Canción de cuna", "error 404 not found", "budget 2026"].enumerated() {
            try t.store.insert(makeClip(text, at: now.addingTimeInterval(Double(index))))
        }
        return t
    }

    private func titles(_ t: TemporaryStore, _ query: String, _ mode: SearchMode) -> [String] {
        t.store.search(query: query, mode: mode, sort: .lastCopy, limit: 10).map(\.title)
    }

    @Test func exactIgnoresCaseAndAccents() throws {
        let t = try seeded()
        #expect(titles(t, "cancion", .exact) == ["Canción de cuna"])
        #expect(titles(t, "CANCIÓN", .exact) == ["Canción de cuna"])
        #expect(titles(t, "launch", .exact) == ["sudo launchctl bootout"])
        #expect(titles(t, "zzz", .exact).isEmpty)
    }

    @Test func exactRespectsRecencyAndLimit() throws {
        let t = try TemporaryStore()
        let now = Date()
        for index in 0..<5 { try t.store.insert(makeClip("match \(index)", at: now.addingTimeInterval(Double(index)))) }
        let rows = t.store.search(query: "match", mode: .exact, sort: .lastCopy, limit: 2)
        #expect(rows.map(\.title) == ["match 4", "match 3"])
    }

    @Test func fuzzyFindsSubsequencesBestFirst() throws {
        let t = try seeded()
        #expect(titles(t, "slb", .fuzzy).contains("sudo launchctl bootout"))
        #expect(titles(t, "qqq", .fuzzy).isEmpty)
    }

    @Test func regexpMatchesRawText() throws {
        let t = try seeded()
        #expect(titles(t, "error \\d+", .regexp) == ["error 404 not found"])
        #expect(titles(t, "(", .regexp).isEmpty)
    }

    @Test func mixedFallsBackThroughTheModes() throws {
        let t = try seeded()
        #expect(titles(t, "launch", .mixed) == ["sudo launchctl bootout"])
        #expect(titles(t, "\\d{4}$", .mixed) == ["budget 2026"])
        #expect(titles(t, "cdn", .mixed).contains("Canción de cuna"))
    }

    @Test func cancelledSearchReturnsNothing() throws {
        let t = try seeded()
        let token = CancelToken()
        token.cancel()
        #expect(t.store.search(query: "e", mode: .exact, sort: .lastCopy, limit: 10, token: token).isEmpty)
    }

    @Test func emptyQueryReturnsNothing() throws {
        let t = try seeded()
        #expect(titles(t, "", .exact).isEmpty)
    }

    @Test func imagesWithoutTextAreSkippedCheaply() throws {
        let t = try TemporaryStore()
        try t.store.insert(makeClip("", payload: Data([1]), kind: .image))
        #expect(titles(t, "a", .exact).isEmpty)
        #expect(titles(t, "a", .fuzzy).isEmpty)
    }
}

@Suite struct MaccyImportTests {
    private func makeMaccyDatabase(at directory: URL, lastCopied: [Double], pin: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent("Storage.sqlite")
        let database = try Database(path: url.path)
        try database.execute("""
        CREATE TABLE ZHISTORYITEM(Z_PK INTEGER PRIMARY KEY, ZNUMBEROFCOPIES INTEGER, ZFIRSTCOPIEDAT TIMESTAMP,
            ZLASTCOPIEDAT TIMESTAMP, ZAPPLICATION VARCHAR, ZPIN VARCHAR, ZTITLE VARCHAR);
        CREATE TABLE ZHISTORYITEMCONTENT(Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB);
        """)
        for (index, seconds) in lastCopied.enumerated() {
            let item = try database.statement("INSERT INTO ZHISTORYITEM VALUES(?1, 3, ?2, ?2, 'com.app', ?3, 't')")
            item.bind(1, Int64(index + 1))
            item.bind(2, seconds)
            item.bind(3, index == 0 ? pin : nil)
            try item.run()
            let content = try database.statement("INSERT INTO ZHISTORYITEMCONTENT(ZITEM, ZTYPE, ZVALUE) VALUES(?1, ?2, ?3)")
            content.bind(1, Int64(index + 1))
            content.bind(2, KnownTypes.text)
            content.bind(3, Data("item \(index)".utf8))
            try content.run()
            content.bind(1, Int64(index + 1))
            content.bind(2, "com.apple.webarchive")
            content.bind(3, Data(repeating: 0xFF, count: 4096))
            try content.run()
        }
        let orphan = try database.statement("INSERT INTO ZHISTORYITEMCONTENT(ZITEM, ZTYPE, ZVALUE) VALUES(NULL, ?1, ?2)")
        orphan.bind(1, KnownTypes.text)
        orphan.bind(2, Data("orphan".utf8))
        try orphan.run()
        return url
    }

    @Test func importsRecentItemsAndDropsWebarchivesAndOrphans() throws {
        let t = try TemporaryStore()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let now = Date()
        let recent = now.addingTimeInterval(-2 * day).timeIntervalSinceReferenceDate
        let old = now.addingTimeInterval(-90 * day).timeIntervalSinceReferenceDate
        let source = try makeMaccyDatabase(at: fixture, lastCopied: [recent, old])

        let result = try t.store.importMaccy(from: source, retention: .standard, options: CaptureOptions(), now: now)
        #expect(result == MaccyImportResult(imported: 1, skipped: 1))
        let rows = t.store.page(sort: .lastCopy, limit: 10)
        #expect(rows.map(\.title) == ["item 0"])
        #expect(rows[0].copyCount == 3)
        #expect(rows[0].sourceApp == "com.app")
        #expect(abs(rows[0].lastCopied.timeIntervalSinceReferenceDate - recent) < 1)
        #expect(try t.store.representations(id: rows[0].id).map(\.uti) == [KnownTypes.text])
    }

    @Test func pinnedItemsImportEvenWhenOld() throws {
        let t = try TemporaryStore()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let now = Date()
        let old = now.addingTimeInterval(-90 * day).timeIntervalSinceReferenceDate
        let source = try makeMaccyDatabase(at: fixture, lastCopied: [old], pin: "b")
        let result = try t.store.importMaccy(from: source, retention: .standard, options: CaptureOptions(), now: now)
        #expect(result.imported == 1)
        #expect(t.store.pinned().first?.pinKey == "b")
    }
}

@Suite struct StagedPayloadTests {
    private func stagedClip(in directory: URL, payload: Data) throws -> CapturedClip {
        var clip = makeClip("staged", payload: payload)
        try clip.stageLargePayloads(in: directory)
        return clip
    }

    private func stagingDirectory(of t: TemporaryStore) throws -> URL {
        let directory = t.store.stagingDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func largePayloadsLeaveTheClipAndReachTheStore() throws {
        let t = try TemporaryStore()
        let directory = try stagingDirectory(of: t)
        let payload = Data(repeating: 5, count: Store.inlineLimit + 10)
        let clip = try stagedClip(in: directory, payload: payload)
        #expect(clip.representations[0].data.isEmpty)
        #expect(clip.representations[0].byteCount == payload.count)

        let id = try t.store.insert(clip, stagedIn: directory)
        #expect(try t.store.representations(id: id)[0].data == payload)
        #expect(t.store.rows(ids: [id])[0].byteSize == Int64(payload.count))
    }

    @Test func smallPayloadsStayInTheClip() throws {
        let t = try TemporaryStore()
        let directory = try stagingDirectory(of: t)
        let clip = try stagedClip(in: directory, payload: Data([1, 2, 3]))
        #expect(clip.representations[0].staged == nil)
        #expect(clip.representations[0].data == Data([1, 2, 3]))
    }

    @Test func clipsSurviveTheTripBetweenProcesses() throws {
        var clip = makeClip("trip")
        clip.thumbnail = ClipThumbnail(data: Data([9]), width: 4, height: 2)
        let outcome = try JSONDecoder().decode(
            CaptureOutcome.self, from: JSONEncoder().encode(CaptureOutcome.clip(clip))
        )
        guard case .clip(let decoded) = outcome else {
            Issue.record("expected a clip")
            return
        }
        #expect(decoded.title == "trip")
        #expect(decoded.hash == clip.hash)
        #expect(decoded.thumbnail == clip.thumbnail)
        #expect(decoded.representations == clip.representations)
        let skipped = try JSONDecoder().decode(
            CaptureOutcome.self, from: JSONEncoder().encode(CaptureOutcome.skipped(.empty))
        )
        guard case .skipped(.empty) = skipped else {
            Issue.record("expected a skip")
            return
        }
    }

    @Test func pasteEntriesPointAtFilesWithoutReadingThem() throws {
        let t = try TemporaryStore()
        let big = Data(repeating: 3, count: Store.inlineLimit + 1)
        let large = try t.store.insert(makeClip("large", payload: big))
        let small = try t.store.insert(makeClip("small"))

        let file = try #require(t.store.pasteEntries(id: large).first)
        #expect(file.inlineData == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(file.path))) == big)
        let inline = try #require(t.store.pasteEntries(id: small).first)
        #expect(inline.inlineData == Data("small".utf8))
        #expect(inline.path == nil)
    }

    @Test func sweepClearsAbandonedStaging() throws {
        let t = try TemporaryStore()
        let directory = try stagingDirectory(of: t)
        _ = try stagedClip(in: directory, payload: Data(repeating: 1, count: Store.inlineLimit + 1))
        try t.store.sweepOrphans()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
