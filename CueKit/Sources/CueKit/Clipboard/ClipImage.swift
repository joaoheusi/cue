import CoreGraphics
import Foundation
import ImageIO

public enum ClipImage {
    static let maxPixels = 200_000_000
    static let thumbnailSize = 64

    static func capture(_ data: Data, type: String, maxPixels: Int = maxPixels) -> CaptureDecision {
        guard data.count <= CaptureFilter.maxImageBytes else { return .skip(.tooLarge) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .skip(.unreadable) }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { return .skip(.tooLarge) }
        guard let thumbnail = downsampled(source, to: thumbnailSize), let encoded = png(thumbnail) else { return .skip(.unreadable) }
        return .capture(ClipCapture(content: .image(type: type, width: width, height: height), data: [type: data], thumbnail: encoded))
    }

    public static func preview(_ data: Data, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { downsampled($0, to: maxPixelSize) }
    }

    private static func downsampled(_ source: CGImageSource, to size: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
