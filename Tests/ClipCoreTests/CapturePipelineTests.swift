import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipCore

private func text(_ string: String) -> Data { Data(string.utf8) }

private func pngData(width: Int, height: Int, alpha: Bool = true) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func clip(_ outcome: CaptureOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> CapturedClip? {
    if case .clip(let clip) = outcome { return clip }
    Issue.record("expected a clip, got \(outcome)", sourceLocation: sourceLocation)
    return nil
}

private func reason(_ outcome: CaptureOutcome) -> SkipReason? {
    if case .skipped(let reason) = outcome { return reason }
    return nil
}

@Suite struct CapturePipelineTests {
    @Test func plainTextBecomesATextClip() throws {
        let source = ReplaySource(items: [[KnownTypes.text: text("Hola Canción")]])
        let result = try #require(clip(CapturePipeline.capture(from: source, frontmostApp: "com.app")))
        #expect(result.kind == .text)
        #expect(result.title == "Hola Canción")
        #expect(result.searchNormalized == "hola cancion")
        #expect(result.sourceApp == "com.app")
        #expect(result.thumbnail == nil)
    }

    @Test func bulkyTypesAreNeverRead() throws {
        let source = ReplaySource(items: [[
            KnownTypes.text: text("hello"),
            KnownTypes.html: text("<b>hello</b>"),
            "com.apple.webarchive": Data(repeating: 1, count: 1024),
        ]])
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(Set(result.representations.map(\.uti)) == [KnownTypes.text, KnownTypes.html])
    }

    @Test func concealedCopiesAreSkipped() {
        let source = ReplaySource(items: [[KnownTypes.text: text("hunter2"), "org.nspasteboard.ConcealedType": Data([1])]])
        #expect(reason(CapturePipeline.capture(from: source)) == .ignoredType)
    }

    @Test func ownWritesAreSkipped() {
        let source = ReplaySource(items: [[KnownTypes.text: text("x"), KnownTypes.ownMarker: Data([1])]])
        #expect(reason(CapturePipeline.capture(from: source)) == .ownWrite)
    }

    @Test func declaredSourceBeatsFrontmostApp() throws {
        let source = ReplaySource(items: [[KnownTypes.text: text("x"), KnownTypes.source: text("com.real.app")]])
        let result = try #require(clip(CapturePipeline.capture(from: source, frontmostApp: "com.front")))
        #expect(result.sourceApp == "com.real.app")
    }

    @Test func ignoredAppsAndPatternsAreSkipped() {
        let source = ReplaySource(items: [[KnownTypes.text: text("token-123")]])
        let byApp = CaptureOptions(rules: IgnoreRules(apps: ["com.bank"]))
        #expect(reason(CapturePipeline.capture(from: source, frontmostApp: "com.bank", options: byApp)) == .ignoredApp)
        let byText = CaptureOptions(rules: IgnoreRules(patterns: ["token-\\d+"]))
        #expect(reason(CapturePipeline.capture(from: source, options: byText)) == .ignoredText)
    }

    @Test func fileURLsWinOverTheIconImage() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/report.pdf").absoluteString
        let source = ReplaySource(items: [[KnownTypes.fileURL: text(url), KnownTypes.tiff: pngData(width: 16, height: 16)]])
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(result.kind == .file)
        #expect(result.title == "~/report.pdf")
        #expect(result.representations.map(\.uti) == [KnownTypes.fileURL])
    }

    @Test func multipleFilesKeepTheirItemIndex() throws {
        let urls = ["/tmp/a.txt", "/tmp/b.txt"].map { URL(fileURLWithPath: $0).absoluteString }
        let source = ReplaySource(items: urls.map { [KnownTypes.fileURL: text($0)] })
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(result.representations.map(\.itemIndex) == [0, 1])
        #expect(result.searchRaw.contains("b.txt"))
    }

    @Test func disabledFilesDoNotFallBackToTheIcon() {
        let source = ReplaySource(items: [[KnownTypes.fileURL: text("file:///tmp/a"), KnownTypes.tiff: Data([1])]])
        let options = CaptureOptions(saveFiles: false)
        #expect(reason(CapturePipeline.capture(from: source, options: options)) == .disabledType)
    }

    @Test func imagesGetASmallThumbnailAndOneRepresentation() throws {
        let png = pngData(width: 2000, height: 1000)
        let source = ReplaySource(items: [[KnownTypes.png: png, KnownTypes.tiff: Data([1, 2, 3])]])
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(result.kind == .image)
        #expect(result.representations.map(\.uti) == [KnownTypes.png])
        let thumbnail = try #require(result.thumbnail)
        #expect(thumbnail.width <= 640)
        #expect(thumbnail.height <= 320)
        #expect(thumbnail.width > thumbnail.height)
        #expect(thumbnail.data.count < png.count)
    }

    @Test func imageWithLoneURLIsAnImage() throws {
        let source = ReplaySource(items: [[KnownTypes.png: pngData(width: 8, height: 8), KnownTypes.text: text("https://a.com/x.png")]])
        #expect(try #require(clip(CapturePipeline.capture(from: source))).kind == .image)
    }

    @Test func textWithImageStaysTextButKeepsTheImage() throws {
        let source = ReplaySource(items: [[KnownTypes.png: pngData(width: 8, height: 8), KnownTypes.text: text("cell A1\tcell B1")]])
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(result.kind == .text)
        #expect(result.representations.contains { $0.uti == KnownTypes.png })
    }

    @Test func oversizedRepresentationsAreNotStored() {
        let source = ReplaySource(items: [[KnownTypes.text: Data(repeating: 0x61, count: 2048)]])
        let options = CaptureOptions(maxRepresentationBytes: 1024)
        #expect(reason(CapturePipeline.capture(from: source, options: options)) == .tooLarge)
    }

    @Test func longTextIsCappedForSearchButKeptWhole() throws {
        let body = String(repeating: "x", count: TextTools.searchTextLimit * 2) + "END"
        let source = ReplaySource(items: [[KnownTypes.text: text(body)]])
        let result = try #require(clip(CapturePipeline.capture(from: source)))
        #expect(result.searchRaw.utf8.count == TextTools.searchTextLimit)
        #expect(result.representations[0].data.count == body.utf8.count)
        #expect(result.title.hasSuffix("END"))
    }

    @Test func htmlOnlyCopyGetsAReadableTitle() throws {
        let source = ReplaySource(items: [[KnownTypes.html: text("<p>Hello <b>world</b></p>")]])
        #expect(try #require(clip(CapturePipeline.capture(from: source))).title == "Hello world")
    }

    @Test func hexTextGetsASwatchColor() throws {
        let source = ReplaySource(items: [[KnownTypes.text: text("142999")]])
        #expect(try #require(clip(CapturePipeline.capture(from: source))).color == 0x142999FF)
    }

    @Test func staleReadsAreDiscarded() {
        let source = ReplaySource(items: [[KnownTypes.text: text("x")]], changeCount: 8)
        #expect(reason(CapturePipeline.capture(from: source, expectedChange: 7)) == .stale)
    }

    @Test func hashDependsOnContentNotOrder() throws {
        let a = ReplaySource(items: [[KnownTypes.text: text("x"), KnownTypes.html: text("<i>x</i>")]])
        let b = ReplaySource(items: [[KnownTypes.html: text("<i>x</i>"), KnownTypes.text: text("x")]])
        let c = ReplaySource(items: [[KnownTypes.text: text("y")]])
        let first = try #require(clip(CapturePipeline.capture(from: a)))
        #expect(first.hash == clip(CapturePipeline.capture(from: b))?.hash)
        #expect(first.hash != clip(CapturePipeline.capture(from: c))?.hash)
    }
}
