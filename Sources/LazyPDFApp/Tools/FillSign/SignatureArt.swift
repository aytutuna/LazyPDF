import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/SignatureArt.cs: turns ink, a typed name or a picture into the transparent image
// that is placed on a page. What needs the system's text and picture frameworks is in SignatureArt+System.swift; the rest is
// arithmetic on pixels.

/// The strokes of a signature being drawn, in the points of the pad they were drawn on. The pad feeds them one point at a time
/// from a finger, a Pencil or a mouse.
public struct SignatureStrokes: Equatable {
    /// The width of the pen in points of the pad.
    public static let penWidth = 2.0

    public private(set) var strokes: [[ViewPoint]] = []

    public init() {}

    public var isEmpty: Bool { strokes.isEmpty }

    /// Starts a stroke at `point`.
    public mutating func begin(_ point: ViewPoint) {
        strokes.append([point])
    }

    /// Carries the stroke being drawn on to `point`; a point that has not moved adds nothing.
    public mutating func extend(_ point: ViewPoint) {
        guard let last = strokes.last?.last, last != point else { return }
        strokes[strokes.count - 1].append(point)
    }

    public mutating func removeLast() {
        if !strokes.isEmpty { strokes.removeLast() }
    }

    public mutating func clear() {
        strokes = []
    }

    /// The smallest box holding every stroke with the pen's width around it; nil without strokes.
    public var bounds: ViewRect? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var left = first.x, right = first.x, top = first.y, bottom = first.y
        for p in points {
            left = min(left, p.x)
            right = max(right, p.x)
            top = min(top, p.y)
            bottom = max(bottom, p.y)
        }
        let half = Self.penWidth / 2
        return ViewRect(left - half, top - half, right - left + Self.penWidth, bottom - top + Self.penWidth)
    }
}

public enum SignatureArt {
    // Drawn and typed signatures are made at this many pixels per point so that they stay sharp when placed larger.
    static let scale = 3.0
    static let maxPictureWidth = 900
    static let margin = 4

    /// The strokes in black on clear, cut to the ink; nil without strokes.
    public static func drawn(_ strokes: SignatureStrokes) -> PdfRgbaImage? {
        guard let bounds = strokes.bounds else { return nil }
        let pad = Double(margin)
        let width = max(1, Int(((bounds.width + 2 * pad) * scale).rounded(.up)))
        let height = max(1, Int(((bounds.height + 2 * pad) * scale).rounded(.up)))
        var cover = [Float](repeating: 0, count: width * height)
        let radius = SignatureStrokes.penWidth / 2 * scale
        func pixel(_ p: ViewPoint) -> ViewPoint {
            ViewPoint((p.x - bounds.x + pad) * scale, (p.y - bounds.y + pad) * scale)
        }
        func stamp(_ at: ViewPoint) {
            let x0 = max(0, Int((at.x - radius - 1).rounded(.down))), x1 = min(width - 1, Int((at.x + radius + 1).rounded(.up)))
            let y0 = max(0, Int((at.y - radius - 1).rounded(.down))), y1 = min(height - 1, Int((at.y + radius + 1).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 {
                for x in x0...x1 {
                    let distance = (pow(Double(x) + 0.5 - at.x, 2) + pow(Double(y) + 0.5 - at.y, 2)).squareRoot()
                    let covered = Float(min(max(radius + 0.5 - distance, 0), 1))
                    if covered > cover[y * width + x] { cover[y * width + x] = covered }
                }
            }
        }
        for stroke in strokes.strokes {
            guard var from = stroke.first.map(pixel) else { continue }
            stamp(from)
            for next in stroke.dropFirst().map(pixel) {
                let length = hypot(next.x - from.x, next.y - from.y)
                let steps = max(1, Int((length / 0.5).rounded(.up)))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    stamp(ViewPoint(from.x + (next.x - from.x) * t, from.y + (next.y - from.y) * t))
                }
                from = next
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height { pixels[i * 4 + 3] = UInt8((cover[i] * 255).rounded()) }
        return trim(PdfRgbaImage(width, height, pixels))
    }

    /// A picture of a signature on paper: the paper becomes see-through, the ink stays. `orientation` is the one the camera
    /// stored in the file (EXIF 1 to 8), which the pixels do not show.
    public static func fromFile(_ file: [UInt8], _ codec: ImageCodec, orientation: Int = 1) -> PdfRgbaImage? {
        guard let first = codec.decodeFile(file)?.first(where: { !$0.tooBig }) else { return nil }
        return trim(paperToClear(shrink(upright(first, orientation))))
    }

    /// The orientation (EXIF 1 to 8) a JPEG carries in its APP1 segment; 1 when it has none or is not a JPEG.
    public static func exifOrientation(_ file: [UInt8]) -> Int {
        guard file.count > 4, file[0] == 0xFF, file[1] == 0xD8 else { return 1 }
        var at = 2
        while at + 4 <= file.count, file[at] == 0xFF {
            let marker = file[at + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0xFF {
                at += marker == 0xFF ? 1 : 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(file[at + 2]) << 8 | Int(file[at + 3])
            let start = at + 4
            let end = at + 2 + length
            if length < 2 || end > file.count { break }
            if marker == 0xE1, end - start >= 14, Array(file[start..<start + 6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                return tiffOrientation(file, start + 6, end)
            }
            at = end
        }
        return 1
    }

    private static func tiffOrientation(_ file: [UInt8], _ tiff: Int, _ end: Int) -> Int {
        let little = file[tiff] == 0x49 && file[tiff + 1] == 0x49
        guard little || (file[tiff] == 0x4D && file[tiff + 1] == 0x4D) else { return 1 }
        func short(_ at: Int) -> Int {
            little ? Int(file[at]) | Int(file[at + 1]) << 8 : Int(file[at]) << 8 | Int(file[at + 1])
        }
        func long(_ at: Int) -> Int {
            little ? short(at) | short(at + 2) << 16 : short(at) << 16 | short(at + 2)
        }
        guard tiff + 8 <= end else { return 1 }
        let ifd = tiff + long(tiff + 4)
        guard ifd >= tiff, ifd + 2 <= end else { return 1 }
        for i in 0..<short(ifd) {
            let entry = ifd + 2 + i * 12
            if entry + 12 > end { break }
            if short(entry) == 0x0112 && short(entry + 2) == 3 {
                return min(max(short(entry + 8), 1), 8)
            }
        }
        return 1
    }

    /// A JPEG turned the way its camera said it was held, so that its pixels and the PDF agree; other files come back as they are.
    public static func uprightFile(_ file: [UInt8], _ codec: ImageCodec) -> [UInt8] {
        guard file.count > 2, file[0] == 0xFF, file[1] == 0xD8 else { return file }
        let orientation = exifOrientation(file)
        guard (2...8).contains(orientation), let frame = codec.decodeFile(file)?.first else { return file }
        let made = codec.encodeJpeg(upright(frame, orientation), 92)
        return made.isEmpty ? file : made
    }

    /// The picture turned a quarter clockwise.
    public static func turn(_ image: PdfRgbaImage) -> PdfRgbaImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: image.rgba.count)
        for y in 0..<h {
            for x in 0..<w {
                let to = (x * h + (h - 1 - y)) * 4
                let from = (y * w + x) * 4
                for c in 0..<4 { pixels[to + c] = image.rgba[from + c] }
            }
        }
        return PdfRgbaImage(h, w, pixels)
    }

    static func mirrored(_ image: PdfRgbaImage) -> PdfRgbaImage {
        let w = image.width
        var pixels = image.rgba
        for y in 0..<image.height {
            for x in 0..<w {
                let to = (y * w + x) * 4
                let from = (y * w + (w - 1 - x)) * 4
                for c in 0..<4 { pixels[to + c] = image.rgba[from + c] }
            }
        }
        return PdfRgbaImage(w, image.height, pixels)
    }

    static func upright(_ image: PdfRgbaImage, _ orientation: Int) -> PdfRgbaImage {
        guard orientation >= 2 && orientation <= 8 else { return image }
        let quarters: Int
        switch orientation {
        case 3, 4: quarters = 2
        case 5, 6: quarters = 1
        case 7, 8: quarters = 3
        default: quarters = 0
        }
        var made = image
        for _ in 0..<quarters { made = turn(made) }
        return [2, 4, 5, 7].contains(orientation) ? mirrored(made) : made
    }

    // The picture is averaged down box by box.
    static func shrink(_ image: PdfRgbaImage) -> PdfRgbaImage {
        guard image.width > maxPictureWidth else { return image }
        let factor = Double(maxPictureWidth) / Double(image.width)
        let width = maxPictureWidth, height = max(1, Int((Double(image.height) * factor).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let y0 = min(Int((Double(y) / factor).rounded(.down)), image.height - 1), y1 = max(y0 + 1, min(image.height, Int((Double(y + 1) / factor).rounded(.up))))
            for x in 0..<width {
                let x0 = min(Int((Double(x) / factor).rounded(.down)), image.width - 1), x1 = max(x0 + 1, min(image.width, Int((Double(x + 1) / factor).rounded(.up))))
                var sum = [Int](repeating: 0, count: 4)
                for sy in y0..<min(y1, image.height) {
                    for sx in x0..<min(x1, image.width) {
                        for c in 0..<4 { sum[c] += Int(image.rgba[(sy * image.width + sx) * 4 + c]) }
                    }
                }
                let count = max(1, (min(y1, image.height) - y0) * (min(x1, image.width) - x0))
                for c in 0..<4 { pixels[(y * width + x) * 4 + c] = UInt8(sum[c] / count) }
            }
        }
        return PdfRgbaImage(width, height, pixels)
    }

    // A photo has no alpha and a grey cast over the paper, so the cut-off sits a little below white and fades in over the next
    // stretch of darkness to keep the edge of the pen soft.
    static func paperToClear(_ image: PdfRgbaImage) -> PdfRgbaImage {
        var pixels = image.rgba
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            pixels[i + 3] = UInt8(Int(pixels[i + 3]) * min(max((235 - luma) * 255 / 100, 0), 255) / 255)
        }
        return PdfRgbaImage(image.width, image.height, pixels)
    }

    /// The picture cut to the part that is not see-through, with a thin border; a picture with nothing in it comes back as it is.
    static func trim(_ image: PdfRgbaImage) -> PdfRgbaImage {
        var left = image.width, top = image.height, right = -1, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.rgba[(y * image.width + x) * 4 + 3] >= 8 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        if right < 0 { return image }
        left = max(0, left - margin)
        top = max(0, top - margin)
        right = min(image.width - 1, right + margin)
        bottom = min(image.height - 1, bottom + margin)
        let w = right - left + 1, h = bottom - top + 1
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let from = ((top + y) * image.width + left) * 4
            pixels.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: image.rgba[from..<from + w * 4])
        }
        return PdfRgbaImage(w, h, pixels)
    }
}
