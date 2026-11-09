#if canImport(CoreText) && canImport(ImageIO)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LazyPDFKit

// The part of windows/LazyPDF.App/Tools/FillSign/SignatureArt.cs and SignatureMaker.xaml.cs that draws with the system: a typed name
// in a handwriting face, and the orientation a camera stored in a picture.

@MainActor
public final class SystemSignature: SignatureSystem {
    // Handwriting faces the Mac and iOS ship, tried in this order; the plain face is there so the list is never empty.
    private static let candidates = ["Snell Roundhand", "Bradley Hand", "Savoye LET", "Zapfino", "Noteworthy", "Apple Chancery",
                                     "Brush Script MT", "Marker Felt", "Helvetica"]

    public let faces: [String]

    public init() {
        let installed = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).map { $0.lowercased() })
        let found = Self.candidates.filter { installed.contains($0.lowercased()) }
        faces = found.isEmpty ? ["Helvetica"] : found
    }

    public func typed(_ text: String, face: String) -> PdfRgbaImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = CTFontCreateWithName(face as CFString, 40, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        guard let string = CFAttributedStringCreate(nil, trimmed as CFString, attributes as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let scale = SignatureArt.scale
        let margin = Double(SignatureArt.margin)
        let w = max(1, Int(((width + 2 * margin) * scale).rounded(.up)))
        let h = max(1, Int(((Double(ascent + descent) + 2 * margin) * scale).rounded(.up)))
        guard w * h <= 1 << 24 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.textPosition = CGPoint(x: margin, y: Double(descent) + margin)
            CTLineDraw(line, context)
            return true
        }
        return drawn ? SignatureArt.trim(PdfRgbaImage(w, h, pixels)) : nil
    }

    public func orientation(of file: [UInt8]) -> Int {
        guard let source = CGImageSourceCreateWithData(Data(file) as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let value = properties[kCGImagePropertyOrientation] as? Int, (1...8).contains(value) else { return 1 }
        return value
    }
}
#endif
