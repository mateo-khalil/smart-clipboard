import AppKit
import ApplicationServices
import ClipCore

@MainActor
public enum Paster {
    /// Writes an item back to the pasteboard and returns the new change count.
    /// With `plainTextOnly`, formatting goes away, but an image or a file
    /// has no plain form and is written unchanged.
    @discardableResult
    public static func write(_ representations: [ClipRepresentation], plainTextOnly: Bool) -> Int {
        var kept = representations
        if plainTextOnly {
            let plain = representations.filter { $0.uti == KnownTypes.text || $0.uti == KnownTypes.fileURL }
            if !plain.isEmpty { kept = plain }
        }
        let groups = Dictionary(grouping: kept, by: \.itemIndex).sorted { $0.key < $1.key }
        var items: [NSPasteboardItem] = groups.map { _, group in
            let item = NSPasteboardItem()
            for representation in group {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti))
            }
            return item
        }
        if items.isEmpty { items = [NSPasteboardItem()] }
        items[0].setData(Data(), forType: NSPasteboard.PasteboardType(KnownTypes.ownMarker))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// Sends ⌘V to the frontmost app. Flags are set explicitly: otherwise a
    /// ⇧ still held from ⇧⌘↩ would turn this into "paste and match style".
    @discardableResult
    public static func postPaste() -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval
        )
        let key = CGKeyCode(KeyboardLayout.commandKeyCode(for: "v", fallback: 9))
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        // 0x08 is the device bit for the left ⌘ key, which some apps check.
        let flags: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    public static func clearSystemClipboard() {
        NSPasteboard.general.clearContents()
    }
}
