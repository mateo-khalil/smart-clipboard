// Puts hard-to-produce content on the general pasteboard for the capture tests.
//   poke concealed <text>     a password-manager style copy
//   poke image <file>         raw PNG bytes
//   poke files <path> ...     several file URLs
//   poke slow <seconds>       promised text whose provider takes that long to answer
import AppKit

final class SlowProvider: NSObject, NSPasteboardItemDataProvider {
    let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: delay)
        item.setString("slow payload", forType: type)
    }
}

let arguments = CommandLine.arguments
let pasteboard = NSPasteboard.general
pasteboard.clearContents()

switch arguments[1] {
case "concealed":
    let item = NSPasteboardItem()
    item.setString(arguments[2], forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.writeObjects([item])
case "image":
    pasteboard.setData(try Data(contentsOf: URL(fileURLWithPath: arguments[2])), forType: .png)
case "files":
    // One pasteboard item per file, the way Finder writes a multi-selection.
    pasteboard.writeObjects(arguments.dropFirst(2).map { path in
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    })
case "slow":
    let delay = TimeInterval(arguments[2]) ?? 3
    let provider = SlowProvider(delay: delay)
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.string])
    pasteboard.writeObjects([item])
    // The provider only answers while this process is alive.
    RunLoop.current.run(until: Date().addingTimeInterval(delay + 3))
    withExtendedLifetime(provider) {}
default:
    fatalError("unknown mode")
}
