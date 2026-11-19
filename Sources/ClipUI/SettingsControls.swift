import AppKit
import ClipCore
import ClipPlatform

/// Bridges target-action to closures. AppKit holds targets weakly, so the
/// factory keeps them alive for as long as the tab exists.
private final class ActionBox: NSObject {
    let body: (Any?) -> Void

    init(_ body: @escaping (Any?) -> Void) {
        self.body = body
    }

    @objc func fire(_ sender: Any?) {
        body(sender)
    }
}

@MainActor
final class ControlFactory {
    private var boxes: [ActionBox] = []

    private func connect(_ control: NSControl, _ body: @escaping (Any?) -> Void) {
        let box = ActionBox(body)
        boxes.append(box)
        control.target = box
        control.action = #selector(ActionBox.fire(_:))
    }

    func checkbox(_ title: String, isOn: Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = isOn ? .on : .off
        connect(button) { sender in set((sender as? NSButton)?.state == .on) }
        return button
    }

    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        connect(button) { _ in action() }
        return button
    }

    func popup(_ titles: [String], selected: Int, _ set: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selected)
        connect(popup) { sender in set((sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        return popup
    }

    /// A number field with a stepper, like Maccy's history size control.
    func number(value: Int, range: ClosedRange<Int>, step: Int = 1, _ set: @escaping (Int) -> Void) -> NSView {
        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        field.formatter = formatter

        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(step)
        stepper.integerValue = value

        connect(field) { [weak stepper] sender in
            guard let number = (sender as? NSTextField)?.integerValue else { return }
            stepper?.integerValue = number
            set(number)
        }
        connect(stepper) { [weak field] sender in
            guard let number = (sender as? NSStepper)?.integerValue else { return }
            field?.integerValue = number
            set(number)
        }
        let stack = NSStackView(views: [field, stepper])
        stack.spacing = 4
        return stack
    }

    func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    func note(_ text: String, width: CGFloat = 400) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// Two columns: right-aligned captions, then controls.
    func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        return grid
    }

    func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return stack
    }

    func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }
}

/// Click, then press the new shortcut. Esc cancels and ⌫ removes it.
@MainActor
final class ShortcutRecorder: NSButton {
    private let placeholder = "Not set"
    private var recording = false
    private var combo: KeyCombo?
    private let onChange: (KeyCombo?) -> Void

    init(combo: KeyCombo?, onChange: @escaping (KeyCombo?) -> Void) {
        self.combo = combo
        self.onChange = onChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func refreshTitle() {
        title = recording ? "Type shortcut…" : combo.map(KeyNames.string(for:)) ?? placeholder
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        recording = true
        refreshTitle()
        window?.makeFirstResponder(self)
        // Otherwise pressing the current shortcut would open the panel instead.
        GlobalHotKey.shared.suspend()
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        refreshTitle()
        GlobalHotKey.shared.resume()
    }

    private func capture(_ event: NSEvent) {
        let modifiers = carbonModifiers(event.modifierFlags)
        switch (event.keyCode, modifiers) {
        case (53, 0):
            finishRecording()
        case (51, 0):
            combo = nil
            finishRecording()
            onChange(nil)
        default:
            // A shortcut without modifiers would swallow normal typing.
            guard modifiers != 0 else {
                NSSound.beep()
                return
            }
            combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            finishRecording()
            onChange(combo)
        }
    }

    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }
}
