import Foundation

// Twin of windows/LazyPDF.Core/Export/PageImages.cs: pages as picture files, drawn by the system's renderer. A dpi or a
// quality out of range is thrown as `ArgumentException`, where the C# throws ArgumentOutOfRangeException: a settings
// dialog can cause it.

public enum PageImages {
    private static let maxDpi = 1200.0

    /// The page as a PNG (alpha kept when the renderer gives any); nil when the renderer cannot draw it. Throws
    /// `ArgumentException` when `dpi` is not above 0 and at most 1200.
    public static func png(_ renderer: PageRenderer, _ pageIndex: Int, _ dpi: Double) throws -> [UInt8]? {
        try checkDpi(dpi)
        guard let image = renderer.render(pageIndex, dpi) else { return nil }
        return try PngWriter.encode(image)
    }

    /// The page as a JPEG, any transparency flattened onto white; nil when the renderer cannot draw it or the codec cannot
    /// encode it. Throws `ArgumentException` when `dpi` or `quality` (1 to 100) is out of range.
    public static func jpeg(_ renderer: PageRenderer, _ codec: ImageCodec, _ pageIndex: Int, _ dpi: Double, _ quality: Int = 85) throws -> [UInt8]? {
        try checkDpi(dpi)
        if quality < 1 || quality > 100 { throw ArgumentException("quality") }
        guard let image = renderer.render(pageIndex, dpi) else { return nil }
        var rgba = image.rgba
        var i = 0
        while i + 3 < rgba.count {
            defer { i += 4 }
            let alpha = Int(rgba[i + 3])
            if alpha == 255 { continue }
            for c in 0..<3 { rgba[i + c] = UInt8(truncatingIfNeeded: (Int(rgba[i + c]) * alpha + 255 * (255 - alpha) + 127) / 255) }
            rgba[i + 3] = 255
        }
        return codec.encodeJpeg(PdfRgbaImage(image.width, image.height, rgba), quality)
    }

    private static func checkDpi(_ dpi: Double) throws {
        if !(dpi > 0 && dpi <= maxDpi) { throw ArgumentException("dpi") }
    }
}
