import Foundation

public enum ClipKind: Int, Sendable, Codable {
    case text = 0
    case image = 1
    case file = 2
}

/// A large payload the helper already wrote to disk, named by its digest.
public struct StagedFile: Sendable, Equatable, Codable {
    public var digest: String
    public var size: Int

    public init(digest: String, size: Int) {
        self.digest = digest
        self.size = size
    }
}

/// One stored pasteboard type. `itemIndex` keeps multi-item copies (such as a
/// Finder multi-selection) restorable as separate pasteboard items. Coming from
/// the helper, a large payload has empty `data` and a `staged` file instead.
public struct ClipRepresentation: Sendable, Equatable, Codable {
    public var uti: String
    public var itemIndex: Int
    public var data: Data
    public var staged: StagedFile?

    public init(uti: String, itemIndex: Int, data: Data, staged: StagedFile? = nil) {
        self.uti = uti
        self.itemIndex = itemIndex
        self.data = data
        self.staged = staged
    }

    public var byteCount: Int { staged?.size ?? data.count }
}

/// One entry of a write to the pasteboard: inline bytes, or a payload file.
public struct PasteEntry: Sendable, Equatable, Codable {
    public var uti: String
    public var itemIndex: Int
    public var inlineData: Data?
    public var path: String?

    public init(uti: String, itemIndex: Int, inlineData: Data?, path: String?) {
        self.uti = uti
        self.itemIndex = itemIndex
        self.inlineData = inlineData
        self.path = path
    }
}

public struct ClipThumbnail: Sendable, Equatable, Codable {
    public var data: Data
    public var width: Int
    public var height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// A copy that passed the filters and is ready to be stored.
public struct CapturedClip: Sendable, Codable {
    public var kind: ClipKind
    public var title: String
    public var color: UInt32?
    public var searchRaw: String
    public var searchNormalized: String
    public var representations: [ClipRepresentation]
    public var thumbnail: ClipThumbnail?
    public var sourceApp: String?
    public var hash: Data
    public var firstCopied: Date
    public var lastCopied: Date
    public var copyCount: Int
    public var pinKey: String?

    public init(
        kind: ClipKind, title: String, color: UInt32?, searchRaw: String, searchNormalized: String,
        representations: [ClipRepresentation], thumbnail: ClipThumbnail?, sourceApp: String?, hash: Data,
        firstCopied: Date, lastCopied: Date, copyCount: Int = 1, pinKey: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.color = color
        self.searchRaw = searchRaw
        self.searchNormalized = searchNormalized
        self.representations = representations
        self.thumbnail = thumbnail
        self.sourceApp = sourceApp
        self.hash = hash
        self.firstCopied = firstCopied
        self.lastCopied = lastCopied
        self.copyCount = copyCount
        self.pinKey = pinKey
    }
}

/// What the panel needs to draw a row. Deliberately free of payload bytes.
public struct ClipRow: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var kind: ClipKind
    public var title: String
    public var color: UInt32?
    public var thumbWidth: Int
    public var thumbHeight: Int
    public var pinKey: String?
    public var sourceApp: String?
    public var firstCopied: Date
    public var lastCopied: Date
    public var copyCount: Int
    public var byteSize: Int64

    public init(
        id: Int64, kind: ClipKind, title: String, color: UInt32?, thumbWidth: Int, thumbHeight: Int,
        pinKey: String?, sourceApp: String?, firstCopied: Date, lastCopied: Date, copyCount: Int, byteSize: Int64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.color = color
        self.thumbWidth = thumbWidth
        self.thumbHeight = thumbHeight
        self.pinKey = pinKey
        self.sourceApp = sourceApp
        self.firstCopied = firstCopied
        self.lastCopied = lastCopied
        self.copyCount = copyCount
        self.byteSize = byteSize
    }
}

public enum HistorySort: Int, Sendable, CaseIterable {
    case lastCopy = 0
    case firstCopy = 1
    case copyCount = 2

    public var title: String {
        switch self {
        case .lastCopy: return "Time of last copy"
        case .firstCopy: return "Time of first copy"
        case .copyCount: return "Number of copies"
        }
    }
}

public enum SearchMode: Int, Sendable, CaseIterable {
    case exact = 0
    case fuzzy = 1
    case regexp = 2
    case mixed = 3

    public var title: String {
        switch self {
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        case .regexp: return "Regexp"
        case .mixed: return "Mixed"
        }
    }
}

public struct RetentionPolicy: Sendable, Equatable {
    /// `nil` keeps items forever.
    public var maxAgeDays: Int?
    public var maxItems: Int
    public var maxBytes: Int64

    public init(maxAgeDays: Int?, maxItems: Int, maxBytes: Int64) {
        self.maxAgeDays = maxAgeDays
        self.maxItems = maxItems
        self.maxBytes = maxBytes
    }

    public static let standard = RetentionPolicy(maxAgeDays: 30, maxItems: 10_000, maxBytes: 5 * 1_073_741_824)
}

public struct PageCursor: Sendable, Equatable {
    public var key: Double
    public var id: Int64

    public init(key: Double, id: Int64) {
        self.key = key
        self.id = id
    }
}

/// A shortcut in Carbon terms, the same format Maccy persists.
public struct KeyCombo: Sendable, Equatable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier bits, repeated here so the core needs no Carbon import.
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096
}
