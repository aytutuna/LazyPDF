#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/WicImageCodec.cs. The picture codecs the engine leaves to the system, on
// ImageIO: JPEG, PNG, TIFF (every frame), BMP, GIF and HEIC where the system has it, and JPEG encoding. ImageIO finds
// the decoder by the bytes, not the name.
//
// A frame is decoded when it is asked for, so one too big to hold is passed over by the size in its header alone.
// ImageIO's PNG output is already straight RGBA and is copied as it is. Anything else is drawn into a premultiplied
// context, since ImageIO draws into no other, so a see-through pixel comes back through a division and loses colour as
// its alpha falls.

public final class ImageIOCodec: ImageCodec {
    private static let maxFrames = 2000
    // What Windows' WIC decoders read; ImageIO also knows PSD, ICO, camera RAW, WebP and PDF.
    private static let types: Set<String> = ["public.jpeg", "public.png", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif",
                                             "public.heic", "public.heif", "public.jpeg-2000"]

    public init() {}

    public func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? {
        guard codec == "DCTDecode" || codec == "JPXDecode" else { return nil }
        return decodeFile(data)?.first
    }

    public func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
        guard let source = CGImageSourceCreateWithData(Data(file) as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, Self.types.contains(type) else { return nil }
        let count = min(CGImageSourceGetCount(source), Self.maxFrames)
        guard count > 0 else { return nil }
        var frames: [PdfRgbaImage] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let (size, overflow) = width.multipliedReportingOverflow(by: height)
            if overflow || size < 0 || size > PdfImageSamples.maxPixels { continue }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), let frame = Self.rgba(image) else { return nil }
            let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 0, dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? 0
            frames.append(PdfRgbaImage(frame.width, frame.height, frame.rgba, dpiX: dpiX, dpiY: dpiY))
        }
        return frames
    }

    public func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] {
        guard image.width > 0, image.height > 0, let picture = Self.overWhite(image) else { return [] }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return [] }
        let options = [kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 1), 100)) / 100]
        CGImageDestinationAddImage(destination, picture, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? [UInt8](data as Data) : []
    }

    private static func rgba(_ image: CGImage) -> PdfRgbaImage? {
        let width = image.width, height = image.height
        // The size is the codestream's own, whatever the dictionary says, and width * height * 4 can wrap.
        guard width > 0, height > 0, width * height <= PdfImageSamples.maxPixels else { return nil }
        if let straight = straightCopy(image) { return straight }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha == 0 || alpha == 255 { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha)) }
        }
        return PdfRgbaImage(width, height, pixels)
    }

    private static func straightCopy(_ image: CGImage) -> PdfRgbaImage? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
              image.bitmapInfo.intersection(.byteOrderMask).rawValue == 0, image.colorSpace?.model == .rgb,
              let data = image.dataProvider?.data else { return nil }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        guard stride >= width * 4, CFDataGetLength(data) >= stride * (height - 1) + width * 4, let source = CFDataGetBytePtr(data) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            pixels.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: row * width * 4).copyMemory(from: source + row * stride, byteCount: width * 4) }
        }
        return PdfRgbaImage(width, height, pixels)
    }

    // JPEG has no alpha: what is see-through goes onto white, as it would on paper.
    private static func overWhite(_ image: PdfRgbaImage) -> CGImage? {
        guard image.width * image.height * 4 == image.rgba.count else { return nil }
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        var o = 0
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            let alpha = Int(image.rgba[i + 3])
            for c in 0..<3 { rgb[o + c] = UInt8((Int(image.rgba[i + c]) * alpha + 255 * (255 - alpha) + 127) / 255) }
            o += 3
        }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: image.width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
