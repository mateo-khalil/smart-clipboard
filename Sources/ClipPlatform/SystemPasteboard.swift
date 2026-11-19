import AppKit
import ClipCore

/// One capture's view of the general pasteboard. Created per capture and used
/// from the capture queue only.
public final class SystemPasteboard: PasteboardSource, @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private lazy var items: [NSPasteboardItem] = pasteboard.pasteboardItems ?? []

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }
    public func itemCount() -> Int { items.count }
    public func types() -> [String] { pasteboard.types?.map(\.rawValue) ?? [] }
    public func types(itemIndex: Int) -> [String] { items[itemIndex].types.map(\.rawValue) }

    public func data(type: String, itemIndex: Int) -> Data? {
        items[itemIndex].data(forType: NSPasteboard.PasteboardType(type))
    }
}
