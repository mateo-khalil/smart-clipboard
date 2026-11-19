import AppKit

final class ClipPanel: NSPanel {
    /// Sees keys before the search field, because ⌥P and similar never reach
    /// `performKeyEquivalent` and would otherwise type a character.
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

final class ClipTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// The search field must keep the keyboard, even after a click on a row.
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func row(for event: NSEvent) -> Int {
        row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = row(for: event)
        if hovered >= 0 { onHover?(hovered) }
    }

    override func mouseDown(with event: NSEvent) {
        let clicked = row(for: event)
        if clicked >= 0 { onClick?(clicked, event.modifierFlags) }
    }
}

/// One footer line: label on the left, shortcut on the right, like a menu item.
final class FooterItem: NSView {
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }
    var action: (() -> Void)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(title: String, shortcut shortcutText: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13)
        shortcut.stringValue = shortcutText
        shortcut.font = NSFont.systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        addSubview(label)
        addSubview(shortcut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - 17) / 2
        label.frame = NSRect(x: 12, y: y, width: bounds.width - 110, height: 17)
        shortcut.frame = NSRect(x: bounds.width - 100, y: y, width: 90, height: 17)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }
    override func mouseUp(with event: NSEvent) { action?() }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// A short message that needs no focus, for use while the panel is closing.
@MainActor
enum Toast {
    private static var window: NSPanel?
    private static var dismissal: DispatchWorkItem?

    static func show(_ text: String) {
        dismissal?.cancel()
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 36)
        label.frame = NSRect(x: 16, y: (size.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.maskImage = roundedMask(radius: 10)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        window = panel

        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                window?.orderOut(nil)
                window = nil
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

/// A stretchable mask, the supported way to round a vibrant view.
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
