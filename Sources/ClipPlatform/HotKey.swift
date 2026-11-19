import Carbon.HIToolbox
import ClipCore

/// The global open shortcut. Carbon hotkeys need no Accessibility permission
/// and cost nothing while idle.
@MainActor
public final class GlobalHotKey {
    public static let shared = GlobalHotKey()

    public var handler: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    private var current: KeyCombo?

    private init() {}

    /// Returns `false` if another app already owns the combination.
    @discardableResult
    public func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        current = combo
        guard let combo else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x5343_4C50), id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference
        )
        return status == noErr
    }

    /// Lets the shortcut recorder receive the current combination as a normal key press.
    public func suspend() {
        unregister()
    }

    public func resume() {
        register(current)
    }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Reads the active keyboard layout. Must run on the main thread.
@MainActor
enum KeyboardLayout {
    static func translate(keyCode: UInt16, carbonModifiers: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), (carbonModifiers >> 8) & 0xFF, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// Finds the physical key that types `character` while ⌘ is held. Going
    /// through ⌘ covers layouts such as "Dvorak - QWERTY ⌘".
    static func commandKeyCode(for character: String, fallback: UInt16) -> UInt16 {
        for code in UInt16(0)..<128 where translate(keyCode: code, carbonModifiers: UInt32(cmdKey)) == character {
            return code
        }
        return fallback
    }
}

@MainActor
public enum KeyNames {
    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func modifierGlyphs(_ modifiers: UInt32) -> String {
        var glyphs = ""
        if modifiers & KeyCombo.control != 0 { glyphs += "⌃" }
        if modifiers & KeyCombo.option != 0 { glyphs += "⌥" }
        if modifiers & KeyCombo.shift != 0 { glyphs += "⇧" }
        if modifiers & KeyCombo.command != 0 { glyphs += "⌘" }
        return glyphs
    }

    public static func string(for combo: KeyCombo) -> String {
        let key = special[combo.keyCode]
            ?? KeyboardLayout.translate(keyCode: UInt16(combo.keyCode), carbonModifiers: 0)?.uppercased()
            ?? "#\(combo.keyCode)"
        return modifierGlyphs(combo.modifiers) + key
    }
}
