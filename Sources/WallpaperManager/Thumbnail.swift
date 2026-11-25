import AppKit
import ImageIO

enum Thumbnail {
    /// A small preview of an image, at most `maxSize` points, rendered sharp on Retina displays.
    /// Uses ImageIO so large photos are not fully decoded into memory.
    static func make(for url: URL, maxSize: NSSize = NSSize(width: 240, height: 150)) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixels = Int(max(maxSize.width, maxSize.height) * 2)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(maxSize.width / width, maxSize.height / height)
        return NSImage(cgImage: cgImage, size: NSSize(width: (width * scale).rounded(), height: (height * scale).rounded()))
    }
}
