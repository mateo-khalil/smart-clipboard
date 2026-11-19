import AppKit
import ClipCore
import ClipPlatform

/// Walks through everything macOS must allow. It shows on first launch, opens
/// again from the menu or Settings, and updates itself as permissions change.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    @MainActor
    private final class Step {
        let icon = NSImageView()
        let status = NSTextField(labelWithString: "")
        let button: NSButton

        init(button: NSButton) {
            self.button = button
        }
    }

    private let preferences: Preferences
    private let window: NSWindow
    private var refreshTimer: Timer?
    private var accessibility: Step!
    private var clipboard: Step!
    private var login: Step!
    var onClose: (() -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        super.init()
        window.title = "Set Up SmartClipboard"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let heading = NSTextField(labelWithString: "Three things and you're done")
        heading.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Your history stays on this Mac. These settings let SmartClipboard work in the background and paste for you.")
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 500

        accessibility = makeStep(buttonTitle: "Grant Access…", action: #selector(grantAccessibility))
        clipboard = makeStep(buttonTitle: "Open Settings…", action: #selector(openClipboardSettings))
        login = makeStep(buttonTitle: "Enable", action: #selector(changeLogin))

        let shortcut = preferences.openShortcut.map(KeyNames.string(for:)) ?? "the menu bar icon"
        let hint = NSTextField(labelWithString: "Open your clipboard anytime with \(shortcut).")
        hint.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let bottom = NSStackView(views: [hint, NSView(), done])
        bottom.orientation = .horizontal
        bottom.distribution = .fill

        let stack = NSStackView(views: [
            heading,
            intro,
            row(accessibility, title: "Accessibility", detail: "Lets SmartClipboard press ⌘V for you, so a selected item lands in the app you were using."),
            row(clipboard, title: "Clipboard access", detail: "Lets SmartClipboard see what you copy while it runs in the background."),
            row(login, title: "Launch at login", detail: "Starts SmartClipboard quietly whenever you log in."),
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.setCustomSpacing(6, after: heading)
        for view in stack.arrangedSubviews[2...] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
        window.contentView = stack
    }

    private func makeStep(buttonTitle: String, action: Selector) -> Step {
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return Step(button: button)
    }

    private func row(_ step: Step, title: String, detail: String) -> NSView {
        step.icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            step.icon.widthAnchor.constraint(equalToConstant: 22),
            step.icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: detail)
        description.font = NSFont.systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = 340
        step.status.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let text = NSStackView(views: [name, description, step.status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let line = NSStackView(views: [step.icon, text, NSView(), step.button])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        return line
    }

    func preparedContent() -> NSView? {
        refresh()
        return window.contentView
    }

    func present() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // macOS has no notification for these, and this only runs while the window is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func set(_ step: Step, done: Bool, warning: Bool = false, status: String, button: String?) {
        let symbol = done ? "checkmark.circle.fill" : warning ? "exclamationmark.triangle.fill" : "circle"
        step.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        step.icon.contentTintColor = done ? .systemGreen : warning ? .systemOrange : .tertiaryLabelColor
        step.status.stringValue = status
        step.status.textColor = done ? .systemGreen : warning ? .systemOrange : .secondaryLabelColor
        step.button.isHidden = button == nil
        if let button { step.button.title = button }
    }

    private func refresh() {
        if Permissions.accessibilityGranted {
            set(accessibility, done: true, status: "Allowed", button: nil)
        } else {
            set(accessibility, done: false, status: "Turn on SmartClipboard in the Accessibility list.", button: "Grant Access…")
        }

        switch Permissions.clipboardAccess {
        case .allowed:
            set(clipboard, done: true, status: "Allowed", button: nil)
        case .asksEachTime:
            set(clipboard, done: false, warning: true, status: "macOS may ask you. Choose Always Allow.", button: "Open Settings…")
        case .denied:
            set(clipboard, done: false, warning: true, status: "Blocked: nothing you copy is being saved.", button: "Open Settings…")
        }

        switch LoginItem.state {
        case .enabled:
            set(login, done: true, status: "On", button: "Turn Off")
        case .needsApproval:
            set(login, done: false, warning: true, status: "Waiting for your approval in Login Items.", button: "Open Login Items…")
        case .disabled:
            set(login, done: false, status: "Off", button: "Turn On")
        case .unavailable:
            set(login, done: false, warning: true, status: "Move SmartClipboard to /Applications first.", button: nil)
        }
    }

    @objc private func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openClipboardSettings() {
        Permissions.openPasteboardSettings()
    }

    @objc private func changeLogin() {
        switch LoginItem.state {
        case .enabled: LoginItem.setEnabled(false)
        case .needsApproval: LoginItem.openSettings()
        default: LoginItem.setEnabled(true)
        }
        refresh()
    }

    @objc private func finish() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        preferences.setupCompleted = true
        onClose?()
    }
}
