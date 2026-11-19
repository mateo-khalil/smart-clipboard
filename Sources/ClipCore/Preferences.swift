import Foundation

public enum PopupPosition: Int, Sendable, CaseIterable {
    case cursor = 0
    case statusItem = 1
    case screenCenter = 2
    case lastPosition = 3

    public var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .statusItem: return "Menu bar icon"
        case .screenCenter: return "Screen center"
        case .lastPosition: return "Last position"
        }
    }
}

public enum PinPlacement: Int, Sendable, CaseIterable {
    case top = 0
    case bottom = 1

    public var title: String { self == .top ? "Top" : "Bottom" }
}

/// Typed access to UserDefaults, which is safe to read from any thread.
public final class Preferences: @unchecked Sendable {
    public static let didChange = Notification.Name("com.mateoduran.smartclipboard.preferencesChanged")
    public static let shared = Preferences(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func combo(_ key: String, _ fallback: KeyCombo?) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(KeyCombo?.self, from: data)
    }

    private func setCombo(_ value: KeyCombo?, _ key: String) {
        set(try? JSONEncoder().encode(value), key)
    }

    private func list(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    // MARK: General

    public var openShortcut: KeyCombo? {
        get { combo("openShortcut", KeyCombo(keyCode: 7, modifiers: KeyCombo.command | KeyCombo.shift)) }
        set { setCombo(newValue, "openShortcut") }
    }

    public var pinShortcut: KeyCombo? {
        get { combo("pinShortcut", KeyCombo(keyCode: 35, modifiers: KeyCombo.option)) }
        set { setCombo(newValue, "pinShortcut") }
    }

    public var deleteShortcut: KeyCombo? {
        get { combo("deleteShortcut", KeyCombo(keyCode: 51, modifiers: KeyCombo.option)) }
        set { setCombo(newValue, "deleteShortcut") }
    }

    public var searchMode: SearchMode {
        get { SearchMode(rawValue: int("searchMode", SearchMode.exact.rawValue)) ?? .exact }
        set { set(newValue.rawValue, "searchMode") }
    }

    public var pasteAutomatically: Bool {
        get { bool("pasteAutomatically", true) }
        set { set(newValue, "pasteAutomatically") }
    }

    public var pasteWithoutFormatting: Bool {
        get { bool("pasteWithoutFormatting", false) }
        set { set(newValue, "pasteWithoutFormatting") }
    }

    /// Flips the mouse wheel back to classic scrolling; the trackpad stays natural.
    public var reverseMouseScroll: Bool {
        get { bool("reverseMouseScroll", false) }
        set { set(newValue, "reverseMouseScroll") }
    }

    /// The mouse side buttons go back and forward in Safari, Finder and similar apps.
    public var mouseSideButtons: Bool {
        get { bool("mouseSideButtons", false) }
        set { set(newValue, "mouseSideButtons") }
    }

    // MARK: Storage

    public var saveFiles: Bool {
        get { bool("saveFiles", true) }
        set { set(newValue, "saveFiles") }
    }

    public var saveImages: Bool {
        get { bool("saveImages", true) }
        set { set(newValue, "saveImages") }
    }

    public var saveText: Bool {
        get { bool("saveText", true) }
        set { set(newValue, "saveText") }
    }

    /// 0 keeps items forever.
    public var retentionDays: Int {
        get { int("retentionDays", 30) }
        set { set(newValue, "retentionDays") }
    }

    public var maxItems: Int {
        get { int("maxItems", RetentionPolicy.standard.maxItems) }
        set { set(newValue, "maxItems") }
    }

    public var maxDiskGB: Int {
        get { int("maxDiskGB", 5) }
        set { set(newValue, "maxDiskGB") }
    }

    public var sortOrder: HistorySort {
        get { HistorySort(rawValue: int("sortOrder", HistorySort.lastCopy.rawValue)) ?? .lastCopy }
        set { set(newValue.rawValue, "sortOrder") }
    }

    public var retention: RetentionPolicy {
        RetentionPolicy(
            maxAgeDays: retentionDays > 0 ? retentionDays : nil,
            maxItems: max(1, maxItems),
            maxBytes: Int64(max(1, maxDiskGB)) * 1_073_741_824
        )
    }

    // MARK: Appearance

    public var popupPosition: PopupPosition {
        get { PopupPosition(rawValue: int("popupPosition", PopupPosition.cursor.rawValue)) ?? .cursor }
        set { set(newValue.rawValue, "popupPosition") }
    }

    public var pinPlacement: PinPlacement {
        get { PinPlacement(rawValue: int("pinPlacement", PinPlacement.top.rawValue)) ?? .top }
        set { set(newValue.rawValue, "pinPlacement") }
    }

    public var imageHeight: Int {
        get { int("imageHeight", 40) }
        set { set(newValue, "imageHeight") }
    }

    public var previewDelayMs: Int {
        get { int("previewDelayMs", 1500) }
        set { set(newValue, "previewDelayMs") }
    }

    public var highlightMatches: Bool {
        get { bool("highlightMatches", true) }
        set { set(newValue, "highlightMatches") }
    }

    public var showSpecialSymbols: Bool {
        get { bool("showSpecialSymbols", true) }
        set { set(newValue, "showSpecialSymbols") }
    }

    public var showMenuIcon: Bool {
        get { bool("showMenuIcon", true) }
        set { set(newValue, "showMenuIcon") }
    }

    public var showRecentInMenuBar: Bool {
        get { bool("showRecentInMenuBar", false) }
        set { set(newValue, "showRecentInMenuBar") }
    }

    public var showSearch: Bool {
        get { bool("showSearch", true) }
        set { set(newValue, "showSearch") }
    }

    public var showTitle: Bool {
        get { bool("showTitle", true) }
        set { set(newValue, "showTitle") }
    }

    public var showFooter: Bool {
        get { bool("showFooter", true) }
        set { set(newValue, "showFooter") }
    }

    public var showAppIcons: Bool {
        get { bool("showAppIcons", false) }
        set { set(newValue, "showAppIcons") }
    }

    public var panelWidth: Int {
        get { int("panelWidth", 450) }
        set { defaults.set(newValue, forKey: "panelWidth") }
    }

    public var panelHeight: Int {
        get { int("panelHeight", 800) }
        set { defaults.set(newValue, forKey: "panelHeight") }
    }

    /// Top-left corner of the panel the last time it was moved, in screen points.
    public var panelTopLeft: (x: Double, y: Double)? {
        get {
            guard defaults.object(forKey: "panelLeft") != nil else { return nil }
            return (defaults.double(forKey: "panelLeft"), defaults.double(forKey: "panelTop"))
        }
        set {
            defaults.set(newValue?.x, forKey: "panelLeft")
            defaults.set(newValue?.y, forKey: "panelTop")
        }
    }

    // MARK: Ignore

    public var ignoredApps: [String] {
        get { list("ignoredApps") }
        set { set(newValue, "ignoredApps") }
    }

    public var onlyListedApps: Bool {
        get { bool("onlyListedApps", false) }
        set { set(newValue, "onlyListedApps") }
    }

    public var ignoredTypes: [String] {
        get { list("ignoredTypes") }
        set { set(newValue, "ignoredTypes") }
    }

    public var ignoredPatterns: [String] {
        get { list("ignoredPatterns") }
        set { set(newValue, "ignoredPatterns") }
    }

    public var rules: IgnoreRules {
        IgnoreRules(
            apps: Set(ignoredApps), onlyListedApps: onlyListedApps,
            types: Set(ignoredTypes), patterns: ignoredPatterns
        )
    }

    // MARK: Advanced

    public var paused: Bool {
        get { bool("paused", false) }
        set { set(newValue, "paused") }
    }

    public var clearHistoryOnQuit: Bool {
        get { bool("clearHistoryOnQuit", false) }
        set { set(newValue, "clearHistoryOnQuit") }
    }

    public var clearClipboardOnQuit: Bool {
        get { bool("clearClipboardOnQuit", false) }
        set { set(newValue, "clearClipboardOnQuit") }
    }

    public var maxItemMiB: Int {
        get { int("maxItemMiB", 64) }
        set { set(newValue, "maxItemMiB") }
    }

    public var checkIntervalMs: Int {
        get { int("checkIntervalMs", 500) }
        set { set(newValue, "checkIntervalMs") }
    }

    public var captureOptions: CaptureOptions {
        CaptureOptions(
            saveText: saveText, saveImages: saveImages, saveFiles: saveFiles,
            maxRepresentationBytes: max(1, maxItemMiB) * 1_048_576, rules: rules
        )
    }

    // MARK: First run

    public var setupCompleted: Bool {
        get { bool("setupCompleted", false) }
        set { defaults.set(newValue, forKey: "setupCompleted") }
    }

    public var loginDefaultApplied: Bool {
        get { bool("loginDefaultApplied", false) }
        set { defaults.set(newValue, forKey: "loginDefaultApplied") }
    }
}
