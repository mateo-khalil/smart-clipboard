import CryptoKit
import Foundation

/// Abstracts the pasteboard so capture can run in tests and in the Maccy import.
public protocol PasteboardSource: Sendable {
    var changeCount: Int { get }
    func itemCount() -> Int
    func types() -> [String]
    func types(itemIndex: Int) -> [String]
    func data(type: String, itemIndex: Int) -> Data?
}

/// A fixed pasteboard held in memory.
public struct ReplaySource: PasteboardSource {
    public var changeCount: Int
    public var items: [[String: Data]]
    public var extraTypes: [String]

    public init(items: [[String: Data]], changeCount: Int = 1, extraTypes: [String] = []) {
        self.items = items
        self.changeCount = changeCount
        self.extraTypes = extraTypes
    }

    public func itemCount() -> Int { items.count }
    public func types() -> [String] { Array(Set(items.flatMap(\.keys))) + extraTypes }
    public func types(itemIndex: Int) -> [String] { Array(items[itemIndex].keys) }
    public func data(type: String, itemIndex: Int) -> Data? { items[itemIndex][type] }
}

public struct CaptureOptions: Sendable, Equatable, Codable {
    public var saveText: Bool
    public var saveImages: Bool
    public var saveFiles: Bool
    public var maxRepresentationBytes: Int
    public var rules: IgnoreRules

    public init(
        saveText: Bool = true, saveImages: Bool = true, saveFiles: Bool = true,
        maxRepresentationBytes: Int = 64 * 1_048_576, rules: IgnoreRules = IgnoreRules()
    ) {
        self.saveText = saveText
        self.saveImages = saveImages
        self.saveFiles = saveFiles
        self.maxRepresentationBytes = maxRepresentationBytes
        self.rules = rules
    }
}

public enum SkipReason: String, Sendable, Equatable, Codable {
    case empty, ownWrite, ignoredType, ignoredApp, ignoredText, disabledType, stale, tooLarge
}

public enum CaptureOutcome: Sendable, Codable {
    case clip(CapturedClip)
    case skipped(SkipReason)
}

public enum ContentDigest {
    /// The file name of a payload, so identical content shares one file.
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CapturedClip {
    /// Above this, a payload lives in its own file instead of the database.
    public static let inlineLimit = 16 * 1024

    /// Moves large payloads out to `directory`, leaving a clip small enough to
    /// hand to the main process without carrying the bytes into it.
    public mutating func stageLargePayloads(in directory: URL) throws {
        for index in representations.indices where representations[index].data.count > Self.inlineLimit {
            let data = representations[index].data
            let digest = ContentDigest.hex(of: data)
            try data.write(to: directory.appendingPathComponent(digest))
            representations[index].data = Data()
            representations[index].staged = StagedFile(digest: digest, size: data.count)
        }
    }
}

public enum CapturePipeline {
    /// Reads only the types that will be kept. `webarchive` and other bulky
    /// representations are never requested, so they never reach memory.
    public static func capture(
        from source: some PasteboardSource,
        expectedChange: Int? = nil,
        frontmostApp: String? = nil,
        now: Date = Date(),
        options: CaptureOptions = CaptureOptions(),
        thumbnailer: (Data) -> ClipThumbnail? = { Thumbnailer.thumbnail(of: $0) }
    ) -> CaptureOutcome {
        let allTypes = source.types()
        guard !allTypes.isEmpty else { return .skipped(.empty) }
        if allTypes.contains(KnownTypes.ownMarker) { return .skipped(.ownWrite) }
        if options.rules.ignores(types: allTypes) { return .skipped(.ignoredType) }

        let app = originatingApp(in: source, types: allTypes) ?? frontmostApp
        if options.rules.ignores(app: app) { return .skipped(.ignoredApp) }

        var kept: [ClipRepresentation] = []
        var oversized = false
        func read(_ type: String, _ index: Int) -> Data? {
            guard let data = source.data(type: type, itemIndex: index), !data.isEmpty else { return nil }
            if data.count > options.maxRepresentationBytes {
                oversized = true
                return nil
            }
            kept.append(ClipRepresentation(uti: type, itemIndex: index, data: data))
            return data
        }

        let count = source.itemCount()
        let itemTypes = (0..<count).map { source.types(itemIndex: $0) }

        // File URLs win over images, or a copied file would be stored as its icon.
        var paths: [String] = []
        if itemTypes.contains(where: { $0.contains(KnownTypes.fileURL) }) {
            guard options.saveFiles else { return .skipped(.disabledType) }
            for (index, types) in itemTypes.enumerated() where types.contains(KnownTypes.fileURL) {
                if let data = read(KnownTypes.fileURL, index) {
                    paths.append(TextTools.displayPath(fileURL: String(decoding: data, as: UTF8.self)))
                }
            }
        }

        var textHeads: [String] = []
        var textTail: String?
        var totalTextBytes = 0
        var html: Data?
        var imageData: Data?

        if paths.isEmpty {
            for (index, types) in itemTypes.enumerated() {
                if options.saveText {
                    if types.contains(KnownTypes.text), let data = read(KnownTypes.text, index) {
                        textHeads.append(TextTools.decodeHead(data))
                        textTail = data.count > TextTools.searchTextLimit
                            ? TextTools.decodeTail(data, limit: TextTools.titleLimit * 4) : nil
                        totalTextBytes += data.count
                    }
                    if types.contains(KnownTypes.rtf) { _ = read(KnownTypes.rtf, index) }
                    if types.contains(KnownTypes.html), let data = read(KnownTypes.html, index) { html = html ?? data }
                }
                if options.saveImages, imageData == nil,
                   let type = KnownTypes.imagePriority.first(where: types.contains) {
                    imageData = read(type, index)
                }
            }
        }

        if kept.isEmpty { return .skipped(oversized ? .tooLarge : .disabledType) }

        var text = textHeads.joined(separator: "\n")
        if text.utf8.count > TextTools.searchTextLimit {
            text = TextTools.decodeHead(Data(text.utf8))
        }
        if text.isEmpty, let html {
            text = TextTools.strippingTags(TextTools.decodeHead(html))
        }

        if !text.isEmpty, options.rules.ignores(text: text) { return .skipped(.ignoredText) }

        let kind: ClipKind
        if !paths.isEmpty {
            kind = .file
        } else if imageData != nil, text.isEmpty || TextTools.looksLikeSingleURL(text) {
            kind = .image
        } else {
            kind = .text
        }

        // Anything read after the pasteboard moved on may mix two different copies.
        if let expectedChange, source.changeCount != expectedChange { return .skipped(.stale) }

        let searchRaw: String
        let title: String
        switch kind {
        case .file:
            searchRaw = paths.joined(separator: "\n")
            title = TextTools.title(head: searchRaw)
        case .image:
            searchRaw = text
            title = text
        case .text:
            searchRaw = text
            title = TextTools.title(head: text, tail: textTail)
        }

        return .clip(CapturedClip(
            kind: kind,
            title: title,
            color: kind == .text && totalTextBytes <= 16 ? TextTools.hexColor(text) : nil,
            searchRaw: searchRaw,
            searchNormalized: TextTools.normalize(searchRaw),
            representations: kept,
            thumbnail: kind == .image ? imageData.flatMap(thumbnailer) : nil,
            sourceApp: app,
            hash: contentHash(of: kept),
            firstCopied: now,
            lastCopied: now
        ))
    }

    static func contentHash(of representations: [ClipRepresentation]) -> Data {
        var hasher = SHA256()
        let ordered = representations.sorted { ($0.itemIndex, $0.uti) < ($1.itemIndex, $1.uti) }
        for representation in ordered {
            hasher.update(data: Data(representation.uti.utf8))
            withUnsafeBytes(of: representation.itemIndex) { hasher.update(bufferPointer: $0) }
            hasher.update(data: representation.data)
        }
        return Data(hasher.finalize())
    }

    private static func originatingApp(in source: some PasteboardSource, types: [String]) -> String? {
        guard types.contains(KnownTypes.source), source.itemCount() > 0,
              let data = source.data(type: KnownTypes.source, itemIndex: 0), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
