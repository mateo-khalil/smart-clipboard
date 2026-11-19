// Handles clipboard data in its own short-lived process. Exiting returns every
// byte it touched, which the main app could not do. See `Helper` in ClipPlatform.
//   cliphelper capture <directory> <change> <app|->
//   cliphelper paste <manifest> <plain|full>
//   cliphelper preview <input> <output> <maxPixelSize>
import ClipCore
import ClipPlatform
import Darwin
import Foundation

// A hung read or decode must not stall the queue waiting for this process.
alarm(20)

func capture(directory: URL, change: Int, app: String?) throws {
    let options = try JSONDecoder().decode(
        CaptureOptions.self, from: Data(contentsOf: directory.appendingPathComponent("options.json"))
    )
    var outcome = CapturePipeline.capture(
        from: SystemPasteboard(), expectedChange: change, frontmostApp: app, options: options
    )
    if case .clip(var clip) = outcome {
        try clip.stageLargePayloads(in: directory)
        outcome = .clip(clip)
    }
    try JSONEncoder().encode(outcome).write(to: directory.appendingPathComponent("result.json"))
}

@MainActor
func paste(manifest: URL, plainTextOnly: Bool) throws {
    let entries = try JSONDecoder().decode([PasteEntry].self, from: Data(contentsOf: manifest))
    let representations = entries.compactMap(Helper.representation(from:))
    guard representations.count == entries.count else { exit(1) }
    Paster.write(representations, plainTextOnly: plainTextOnly)
}

func preview(input: URL, output: URL, maxPixelSize: Int) throws {
    let data = try Data(contentsOf: input, options: .alwaysMapped)
    guard let image = Thumbnailer.encoded(data, maxPixelSize: maxPixelSize) else { exit(1) }
    try image.write(to: output)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { exit(2) }

do {
    switch arguments[1] {
    case "capture" where arguments.count == 5:
        try capture(
            directory: URL(fileURLWithPath: arguments[2], isDirectory: true),
            change: Int(arguments[3]) ?? -1,
            app: arguments[4] == "-" ? nil : arguments[4]
        )
    case "paste" where arguments.count == 4:
        try MainActor.assumeIsolated {
            try paste(manifest: URL(fileURLWithPath: arguments[2]), plainTextOnly: arguments[3] == "plain")
        }
    case "preview" where arguments.count == 5:
        try preview(
            input: URL(fileURLWithPath: arguments[2]), output: URL(fileURLWithPath: arguments[3]),
            maxPixelSize: Int(arguments[4]) ?? 1_040
        )
    default:
        exit(2)
    }
} catch {
    exit(1)
}
