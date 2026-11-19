import CoreImage
import UIKit

/// One Gaussian blur of a still, matching the details backdrop.
///
/// SwiftUI `.blur` redraws every frame. The radius is in points of the view
/// the image fills, so the CI radius is that many pixels in the downscaled still.
enum PreblurredStill {
    private static let cache = NSCache<NSString, UIImage>()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(
        _ image: UIImage,
        key: String,
        radius: CGFloat,
        displayedWidth: CGFloat,
        maxPixelWidth: CGFloat = 640
    ) async -> UIImage? {
        guard radius > 0, displayedWidth > 0 else { return nil }
        let cacheKey = "\(key)#\(Int((radius * 10).rounded()))#\(Int(displayedWidth.rounded()))#\(Int(maxPixelWidth.rounded()))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let rendered = await Task.detached(priority: .userInitiated) {
            render(image, radius: radius, displayedWidth: displayedWidth, maxPixelWidth: maxPixelWidth)
        }.value
        if let rendered {
            cache.setObject(rendered, forKey: cacheKey)
        }
        return rendered
    }

    static func render(
        _ image: UIImage,
        radius: CGFloat,
        displayedWidth: CGFloat,
        maxPixelWidth: CGFloat = 640
    ) -> UIImage? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0, displayedWidth > 0 else {
            return nil
        }
        let scale = min(1, maxPixelWidth / CGFloat(cgImage.width))
        let input = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent.integral
        let pixelsPerPoint = extent.width / displayedWidth
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius * pixelsPerPoint, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
