#if canImport(SwiftUI)
import CoreGraphics
import Foundation
import LazyPDFApp

extension TileBitmap {
    /// The tile as an image the views can draw. The bytes are B, G, R, 255, which Core Graphics reads as little-endian
    /// XRGB, so they need no conversion.
    public var cgImage: CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
