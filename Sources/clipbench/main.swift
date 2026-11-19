// Seeds synthetic histories and measures search, paging and purge, plus the
// resident cost of the store. Usage: clipbench [rows ...]
import ClipCore
import ClipStore
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

func footprintMB() -> Double {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
}

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

let words = [
    "sudo", "launchctl", "bootout", "kubectl", "canción", "reescritura", "permiso", "consentimiento",
    "docker", "error", "budget", "función", "deploy", "clipboard", "memoria", "historial", "página",
    "server", "request", "response", "token", "cluster", "archivo", "imagen", "texto", "buscar",
]

func syntheticText(_ seed: Int) -> String {
    var generator = seed &* 2_654_435_761 &+ 12_345
    func next() -> Int {
        generator ^= generator << 13
        generator ^= generator >> 7
        generator ^= generator << 17
        return abs(generator)
    }
    let length = 8 + next() % 60
    return (0..<length).map { _ in words[next() % words.count] }.joined(separator: " ") + " \(seed)"
}

func run(rows: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipbench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try Store(directory: directory)

    let now = Date()
    let seed = milliseconds {
        for index in 0..<rows {
            let text = syntheticText(index)
            let data = Data(text.utf8)
            // Spread across 60 days so a purge has real work to do.
            let date = now.addingTimeInterval(-Double(index) / Double(rows) * 60 * 86_400)
            let clip = CapturedClip(
                kind: .text, title: TextTools.title(head: text), color: nil, searchRaw: text,
                searchNormalized: TextTools.normalize(text),
                representations: [ClipRepresentation(uti: KnownTypes.text, itemIndex: 0, data: data)],
                thumbnail: nil, sourceApp: "com.bench", hash: Data(SHA256.hash(data: data)),
                firstCopied: date, lastCopied: date
            )
            _ = try? store.insert(clip)
        }
    }

    func measure(_ label: String, repeats: Int = 40, _ body: (Int) -> Void) {
        let times = (0..<repeats).map { index in milliseconds { body(index) } }
        print(String(format: "  %-30@ p50 %8.2f ms   p95 %8.2f ms", label as NSString, percentile(times, 0.5), percentile(times, 0.95)))
    }

    print("rows \(rows)  (seeded in \(Int(seed)) ms, \(store.stats().diskBytes / 1_048_576) MiB on disk)")
    measure("first page, 100 rows") { _ in _ = store.page(sort: .lastCopy, limit: 100) }
    let middle = store.page(sort: .lastCopy, limit: 100).last!
    measure("next page, 100 rows") { _ in
        _ = store.page(sort: .lastCopy, after: Store.cursor(after: middle, sort: .lastCopy), limit: 100)
    }
    let common = ["error", "docker", "buscar", "cancion", "token"]
    measure("exact, common word") { index in
        _ = store.search(query: common[index % common.count], mode: .exact, sort: .lastCopy, limit: 100)
    }
    measure("exact, no match (full scan)") { _ in
        _ = store.search(query: "zzzzqqq", mode: .exact, sort: .lastCopy, limit: 100)
    }
    measure("fuzzy (full scan)", repeats: 15) { index in
        _ = store.search(query: ["dkr", "lnch", "prms"][index % 3], mode: .fuzzy, sort: .lastCopy, limit: 100)
    }
    measure("regexp, no match (full scan)", repeats: 5) { _ in
        _ = store.search(query: "zzz\\d+", mode: .regexp, sort: .lastCopy, limit: 100)
    }
    let purge = milliseconds {
        let result = try? store.purge(policy: .standard, now: now)
        print("  purge removed \(result?.removed ?? -1)")
    }
    print(String(format: "  purge took %.0f ms; footprint %.1f MB", purge, footprintMB()))
}

/// `clipbench --seed <directory> <rows>` leaves a history behind for app-level
/// tests: mostly text, with one image row in five carrying a real thumbnail.
func seed(directory: URL, rows: Int) throws {
    let store = try Store(directory: directory)
    let context = CGContext(
        data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    let thumbnail = Thumbnailer.thumbnail(of: output as Data)

    let now = Date()
    for index in 0..<rows {
        let text = syntheticText(index)
        let isImage = index % 5 == 0
        let data = Data(text.utf8)
        let date = now.addingTimeInterval(-Double(index) / Double(rows) * 25 * 86_400)
        _ = try store.insert(CapturedClip(
            kind: isImage ? .image : .text, title: isImage ? "" : TextTools.title(head: text), color: nil,
            searchRaw: isImage ? "" : text, searchNormalized: isImage ? "" : TextTools.normalize(text),
            representations: [ClipRepresentation(uti: isImage ? KnownTypes.png : KnownTypes.text, itemIndex: 0, data: data)],
            thumbnail: isImage ? thumbnail : nil, sourceApp: "com.bench", hash: Data(SHA256.hash(data: data)),
            firstCopied: date, lastCopied: date
        ))
    }
    print("seeded \(rows) rows, \(store.stats().diskBytes / 1_048_576) MiB")
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--seed", let rows = Int(arguments[3]) {
    try seed(directory: URL(fileURLWithPath: arguments[2], isDirectory: true), rows: rows)
    exit(0)
}

let sizes = arguments.dropFirst().compactMap { Int($0) }
for rows in sizes.isEmpty ? [1_000, 10_000, 100_000] : sizes {
    try autoreleasepool { try run(rows: rows) }
}
