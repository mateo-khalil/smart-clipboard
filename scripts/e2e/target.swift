// A small app that receives pastes and records them for the end-to-end test.
//   target <output-file>
// Its menu binds ⌘V to paste and ⇧⌘V to a marker, the way TextEdit binds
// "Paste and Match Style", which reveals a ⇧ leaking into the synthetic ⌘V.
import AppKit

final class Target: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let output: String
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
    var window: NSWindow?

    init(output: String) {
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let leak = edit.addItem(withTitle: "Leak", action: #selector(recordLeak), keyEquivalent: "V")
        leak.target = self
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = edit
        NSApp.mainMenu = menu

        let window = NSWindow(
            contentRect: NSRect(x: 900, y: 500, width: 420, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "SmartClipboard end-to-end target"
        textView.delegate = self
        textView.isRichText = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) {
        try? textView.string.write(toFile: output, atomically: true, encoding: .utf8)
    }

    @objc func recordLeak() {
        FileManager.default.createFile(atPath: output + ".leak", contents: nil)
    }
}

let delegate = Target(output: CommandLine.arguments[1])
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
