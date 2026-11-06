import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportImageTurn.cs: the eight ways a picture can lie on a page, numbered as the
// Exif orientation tag: 1 upright, 2 mirrored, 3 turned half, 4 mirrored upside down, 5 to 8 the same with a quarter turn.

enum ExportImageTurn {
    /// The orientation of an image whose unit square goes to display space (y down) by `shown`. A slant is read as the
    /// nearest quarter turn.
    static func of(_ shown: PdfMatrix) -> Int {
        if abs(shown.b) <= abs(shown.a) {
            switch (shown.a < 0, shown.d > 0) {
            case (false, false): return 1
            case (true, false): return 2
            case (true, true): return 3
            default: return 4
            }
        }
        switch (shown.b > 0, shown.c < 0) {
        case (true, true): return 5
        case (true, false): return 6
        case (false, false): return 7
        default: return 8
        }
    }

    static func apply(_ image: PdfRgbaImage, _ orientation: Int) -> PdfRgbaImage {
        if orientation == 1 { return image }
        let w = image.width, h = image.height
        let swap = orientation >= 5
        let outWidth = swap ? h : w
        var rgba = [UInt8](repeating: 0, count: image.rgba.count)
        for r in 0..<h {
            for c in 0..<w {
                let (x, y): (Int, Int)
                switch orientation {
                case 2: (x, y) = (w - 1 - c, r)
                case 3: (x, y) = (w - 1 - c, h - 1 - r)
                case 4: (x, y) = (c, h - 1 - r)
                case 5: (x, y) = (r, c)
                case 6: (x, y) = (h - 1 - r, c)
                case 7: (x, y) = (h - 1 - r, w - 1 - c)
                default: (x, y) = (r, w - 1 - c)
                }
                let from = (r * w + c) * 4, to = (y * outWidth + x) * 4
                for k in 0..<4 { rgba[to + k] = image.rgba[from + k] }
            }
        }
        return swap ? PdfRgbaImage(h, w, rgba) : PdfRgbaImage(w, h, rgba)
    }
}
