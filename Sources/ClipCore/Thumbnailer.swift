import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnailer {
    /// Above this ImageIO may fall back to a full decode, so no thumbnail is made.
    static let maxSourcePixels = 256_000_000

    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Scales down through ImageIO, subsampling when the format allows it.
    public static func downscaled(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let size = pixelSize(of: data), size.width * size.height <= maxSourcePixels else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let isOpaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: isOpaque = true
        default: isOpaque = false
        }
        let output = NSMutableData()
        let type = (isOpaque ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        CGImageDestinationAddImage(destination, image, isOpaque ? properties : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public static func encoded(_ data: Data, maxPixelSize: Int) -> Data? {
        downscaled(data, maxPixelSize: maxPixelSize).flatMap(encode)
    }

    /// 40 pt rows at 2x need 80 px of height; the rest leaves room for larger
    /// rows, and the width cap covers wide screenshots.
    public static func thumbnail(of data: Data, maxPixelHeight: Int = 160, maxPixelWidth: Int = 640) -> ClipThumbnail? {
        guard let size = pixelSize(of: data) else { return nil }
        let scale = min(1, min(Double(maxPixelHeight) / Double(size.height), Double(maxPixelWidth) / Double(size.width)))
        let target = max(1, Int((Double(max(size.width, size.height)) * scale).rounded()))
        guard let image = downscaled(data, maxPixelSize: target), let encoded = encode(image) else { return nil }
        return ClipThumbnail(data: encoded, width: image.width, height: image.height)
    }
}
