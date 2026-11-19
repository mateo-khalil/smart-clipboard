// Draws the app icon set. Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let inset = size * 0.09
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.19, yRadius: size * 0.19)
    NSGradient(
        starting: NSColor(srgbRed: 0.27, green: 0.53, blue: 0.98, alpha: 1),
        ending: NSColor(srgbRed: 0.13, green: 0.25, blue: 0.75, alpha: 1)
    )?.draw(in: path, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let bounds = symbol.size
        symbol.draw(in: NSRect(
            x: (size - bounds.width) / 2, y: (size - bounds.height) / 2,
            width: bounds.width, height: bounds.height
        ))
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
