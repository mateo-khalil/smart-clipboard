import Foundation

public enum TextTools {
    public static let searchTextLimit = 64 * 1024
    public static let titleLimit = 300

    /// Lowercases and strips accents, so "cancion" finds "canción".
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Decodes at most `limit` bytes without splitting a UTF-8 sequence, so a
    /// huge copy never has to be decoded whole.
    public static func decodeHead(_ data: Data, limit: Int = searchTextLimit) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        var end = data.startIndex + limit
        while end > data.startIndex, data[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: data[data.startIndex..<end], as: UTF8.self)
    }

    public static func decodeTail(_ data: Data, limit: Int) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        var start = data.endIndex - limit
        while start < data.endIndex, data[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: data[start..<data.endIndex], as: UTF8.self)
    }

    /// Keeps both ends, because the panel truncates in the middle.
    public static func title(head: String, tail: String? = nil, limit: Int = titleLimit) -> String {
        let half = limit / 2
        let start = head.prefix(half)
        if tail == nil, start.endIndex == head.endIndex { return head }
        if tail == nil, head.utf8.count <= limit { return head }
        let source = tail ?? head
        let end = source.suffix(half)
        if tail == nil, start.endIndex >= end.startIndex { return head }
        return start + "…" + end
    }

    public static func displayTitle(_ raw: String, specialSymbols: Bool) -> String {
        guard specialSymbols else {
            let flattened = raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            return flattened.trimmingCharacters(in: .whitespaces)
        }
        let leading = raw.prefix { $0 == " " }.count
        let trailing = leading == raw.count ? 0 : raw.reversed().prefix { $0 == " " }.count
        var text = String(raw.dropFirst(leading).dropLast(trailing))
        text = text
            .replacingOccurrences(of: "\r\n", with: "⏎")
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
        return String(repeating: "·", count: leading) + text + String(repeating: "·", count: trailing)
    }

    /// Parses 3, 4, 6 or 8 hex digits, with an optional `#`, into RGBA.
    public static func hexColor(_ text: String) -> UInt32? {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard [3, 4, 6, 8].contains(digits.utf8.count), let value = UInt32(digits, radix: 16) else { return nil }
        guard digits.utf8.allSatisfy({ $0 != 0x2B && $0 != 0x2D }) else { return nil }
        switch digits.utf8.count {
        case 3:
            let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
            return (r * 17) << 24 | (g * 17) << 16 | (b * 17) << 8 | 0xFF
        case 4:
            let r = (value >> 12) & 0xF, g = (value >> 8) & 0xF, b = (value >> 4) & 0xF, a = value & 0xF
            return (r * 17) << 24 | (g * 17) << 16 | (b * 17) << 8 | (a * 17)
        case 6:
            return value << 8 | 0xFF
        default:
            return value
        }
    }

    public static func looksLikeSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        return !trimmed.contains(where: { $0.isWhitespace })
    }

    public static func strippingTags(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func displayPath(fileURL: String) -> String {
        guard let url = URL(string: fileURL), url.isFileURL else {
            return fileURL.removingPercentEncoding ?? fileURL
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
