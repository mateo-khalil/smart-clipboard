import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

public enum LoginItemState: Sendable {
    case enabled
    case disabled
    case needsApproval
    case unavailable
}

/// `state` is always read from macOS, so the UI cannot drift from reality.
@MainActor
public enum LoginItem {
    public static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        default: return .disabled
        }
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

public enum ClipboardAccess: Sendable {
    case allowed
    case asksEachTime
    case denied
}

@MainActor
public enum Permissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS dialog that adds this app to the Accessibility list.
    public static func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, a global Swift 6 will not touch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    public static func openPasteboardSettings() {
        openPrivacyPane("Privacy_Pasteboard")
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `.default` and `.ask` both still let reads through after a macOS prompt.
    public static var clipboardAccess: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return .asksEachTime
        }
    }

    /// True while a password field or Terminal's Secure Keyboard Entry holds the keyboard.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}
