import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionFlatten.cs: turns a page into a picture of itself with the marks filled in
// the pixels. It is what is left for a page the redaction cannot follow to its end: the page is drawn from the file as it
// stands, so nothing is read from content that was not understood, and the picture holds only what a viewer shows.

enum RedactionFlatten {
    private static let maxDpi = 1200.0
    private static let kept = ["Type", "Parent", "MediaBox", "CropBox", "Rotate", "UserUnit"]

    /// The page's own entries after this are the boxes and the turn, one content stream that places the picture, and resources
    /// that name it and the overlay font. The C# ArgumentOutOfRangeException for a resolution outside 1 to 1200 is an
    /// `ArgumentException`, as the options may come from a setting a user typed.
    static func page(_ work: PdfDocument, _ page: PdfPage, _ marks: [RedactionMark], _ options: RedactionOptions, _ font: PdfDrawFont?) throws {
        let dpi = options.flattenDpi
        if !(dpi > 0 && dpi <= maxDpi) { throw ArgumentException("Specified argument was out of the range of valid values. (Parameter 'options')") }
        guard let drawn = options.renderer?.render(page.index, dpi), drawn.width >= 1, drawn.height >= 1,
              drawn.width * drawn.height <= PdfImageSamples.maxPixels, drawn.rgba.count == drawn.width * drawn.height * 4 else {
            throw InvalidOperationException(RedactionText.notDrawn(page.index))
        }
        let geometry = PageGeometry(page)
        let sx = Double(drawn.width) / geometry.width, sy = Double(drawn.height) / geometry.height
        // The picture is stretched to the page, so one that was drawn with another shape would put the marks in the wrong place.
        if abs(sx - sy) > 1 / geometry.width + 1 / geometry.height { throw InvalidOperationException(RedactionText.notDrawn(page.index)) }
        var pixels = onWhite(drawn.rgba)
        for mark in marks {
            let color = rgb(RedactionOverlay.fillOf(mark, options))
            for q in mark.quads {
                // The corners as the area orders them: the quad can come in any order, and a crossing polygon fills two triangles only.
                let corners: [MarkPoint] = MarkArea.of(q).points
                    .map { geometry.toDisplay($0.x, $0.y) }.map { ($0.x * sx, $0.y * sy) }
                fill(&pixels, drawn.width, drawn.height, corners, color)
            }
        }
        let image = try PdfImageWriter.addRgba(work, drawn.width, drawn.height, pixels)

        // The picture is the displayed page: its top left is the display origin, so the unit square maps through the inverse of the display.
        let (ox, oy) = geometry.toUser(0, geometry.height)
        let (ux, uy) = geometry.toUser(geometry.width, geometry.height)
        let (vx, vy) = geometry.toUser(0, 0)
        let resources = PdfDictionary()
        let name = ContentResources.add(work, resources, "XObject", image.reference, "RdPage")
        let content = ContentWriter().paint(name, PdfMatrix(ux - ox, uy - oy, vx - ox, vy - oy, ox, oy))
        var fontName = ""
        if let font, marks.contains(where: { !($0.overlayText ?? options.overlayText ?? "").isEmpty }) {
            fontName = ContentResources.add(work, resources, "Font", font.reference, "RdF")
        }
        let overlay = RedactionOverlay.build(marks, options, font, fontName)
        for (key, _) in page.dictionary.entries where !kept.contains(key) { page.dictionary.remove(key) }
        page.dictionary["Resources"] = resources
        page.dictionary["Contents"] = try PdfRedactor.store(work, content.toArray() + [0x0A] + overlay)
    }

    // What shows through is white paper, so no soft mask comes along.
    private static func onWhite(_ rgba: [UInt8]) -> [UInt8] {
        var pixels = rgba
        var i = 0
        while i + 3 < pixels.count {
            let alpha = Int(pixels[i + 3])
            var c = 0
            while c < 3 && alpha != 255 {
                pixels[i + c] = UInt8(truncatingIfNeeded: (Int(pixels[i + c]) * alpha + 255 * (255 - alpha) + 127) / 255)
                c += 1
            }
            pixels[i + 3] = 255
            i += 4
        }
        return pixels
    }

    private static func rgb(_ color: [Double]) -> [UInt8] {
        let values: [Double]
        switch color.count {
        case 1: values = [color[0], color[0], color[0]]
        case 3: values = color
        default: values = color.prefix(3).map { 1 - nanMin(1, $0 + color[3]) }
        }
        return values.map { UInt8(truncatingIfNeeded: Int(saturating32: (PdfFunction.clamp($0, 0, 1) * 255).rounded(.toNearestOrEven))) }
    }

    // A pixel the polygon touches is filled, so the edge of a mark never leaves a row of the picture behind.
    private static func fill(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ polygon: [MarkPoint], _ color: [UInt8]) {
        let left = pixel(Geometry.minimum(polygon.map { $0.x }).rounded(.down) - 1, width), right = pixel(Geometry.maximum(polygon.map { $0.x }).rounded(.up) + 1, width)
        let top = pixel(Geometry.minimum(polygon.map { $0.y }).rounded(.down) - 1, height), bottom = pixel(Geometry.maximum(polygon.map { $0.y }).rounded(.up) + 1, height)
        var y = top
        while y <= bottom {
            var x = left
            while x <= right {
                if touches(polygon, Double(x) + 0.5, Double(y) + 0.5) {
                    let i = (y * width + x) * 4
                    pixels[i] = color[0]
                    pixels[i + 1] = color[1]
                    pixels[i + 2] = color[2]
                }
                x += 1
            }
            y += 1
        }
    }

    // Clamped before the cast: a mark far outside the page must still fill what it reaches.
    private static func pixel(_ at: Double, _ size: Int) -> Int { Int(saturating32: PdfFunction.clamp(at, 0, Double(size - 1))) }

    private static func touches(_ polygon: [MarkPoint], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            defer { j = i }
            let (a, b) = (polygon[i], polygon[j])
            if (a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside = !inside }
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length == 0 ? 0 : PdfFunction.clamp(((x - a.x) * dx + (y - a.y) * dy) / length, 0, 1)
            if pow(a.x + t * dx - x, 2) + pow(a.y + t * dy - y, 2) <= 1 { return true }
        }
        return inside
    }
}
