import Foundation

// Twin of windows/LazyPDF.Core/Export/PdfFromPicturesExif.cs: what a JPEG file says about how it is to be shown: JFIF
// density and Exif orientation.

enum JpegMeta {
    private static let defaultDpi = 96.0

    private static func byte(_ file: [UInt8], _ at: Int) -> Int? {
        at >= 0 && at < file.count ? Int(file[at]) : nil
    }

    private static func ascii(_ file: [UInt8], _ at: Int, _ length: Int) -> String? {
        guard at >= 0, length >= 0, at <= file.count - length else { return nil }
        return String(decoding: file[at..<(at + length)], as: UTF8.self)
    }

    // The density of a JFIF header, when it says dots per inch or per centimetre and is plausible.
    static func density(_ file: [UInt8]) -> (x: Double, y: Double) {
        if file.count < 18 || file[2] != 0xFF || file[3] != 0xE0 || ascii(file, 6, 4) != "JFIF" { return (defaultDpi, defaultDpi) }
        let unit: Double = file[13] == 1 ? 1 : file[13] == 2 ? 2.54 : 0
        let x = unit * Double(Int(file[14]) << 8 | Int(file[15])), y = unit * Double(Int(file[16]) << 8 | Int(file[17]))
        return x >= 50 && x <= 1200 && y >= 50 && y <= 1200 ? (x, y) : (defaultDpi, defaultDpi)
    }

    /// The Exif orientation (1 to 8, tag 0x0112 of the first IFD); 1 when there is none.
    static func orientation(_ file: [UInt8]) -> Int {
        var p = 2
        while p + 4 <= file.count && file[p] == 0xFF && file[p + 1] != 0xDA && file[p + 1] != 0xD9 {
            let length = Int(file[p + 2]) << 8 | Int(file[p + 3])
            let end = min(file.count, p + 2 + length)
            if file[p + 1] == 0xE1 && end - p >= 18 && ascii(file, p + 4, 4) == "Exif" { return tiff(file, p + 10, end) }
            p += 2 + length
        }
        return 1
    }

    private static func tiff(_ file: [UInt8], _ start: Int, _ end: Int) -> Int {
        guard let first = byte(file, start), let second = byte(file, start + 1) else { return 1 }
        let big = first == UInt8(ascii: "M")
        if first != (big ? UInt8(ascii: "M") : UInt8(ascii: "I")) || second != first { return 1 }
        func u16(_ at: Int) -> Int? {
            guard let a = byte(file, at), let b = byte(file, at + 1) else { return nil }
            return big ? a << 8 | b : b << 8 | a
        }
        func u32(_ at: Int) -> Int? {
            guard let high = u16(big ? at : at + 2), let low = u16(big ? at + 2 : at) else { return nil }
            return high << 16 | low
        }
        guard let offset = u32(start + 4) else { return 1 }
        let ifd = start + offset
        if ifd + 2 > end { return 1 }
        guard let count = u16(ifd) else { return 1 }
        var i = 0
        while i < count && ifd + 2 + 12 * (i + 1) <= end {
            let entry = ifd + 2 + 12 * i
            i += 1
            if u16(entry) != 0x0112 { continue }
            guard let value = u16(entry + 8) else { return 1 }
            return value >= 1 && value <= 8 ? value : 1
        }
        return 1
    }

    /// Where the unit square of an image goes so that it shows with `orientation` undone in a box of `w` by `h` whose
    /// lower left corner is at (`x`, `y`).
    static func placement(_ orientation: Int, _ w: Double, _ h: Double, _ x: Double, _ y: Double) -> PdfMatrix {
        // Shown position as (xa u + xb t + xc, ya u + yb t + yc) of the column u and row t, both from 0 to 1 and t downwards.
        let (xa, xb, xc, ya, yb, yc): (Double, Double, Double, Double, Double, Double)
        switch orientation {
        case 2: (xa, xb, xc, ya, yb, yc) = (-1, 0, 1, 0, 1, 0)
        case 3: (xa, xb, xc, ya, yb, yc) = (-1, 0, 1, 0, -1, 1)
        case 4: (xa, xb, xc, ya, yb, yc) = (1, 0, 0, 0, -1, 1)
        case 5: (xa, xb, xc, ya, yb, yc) = (0, 1, 0, 1, 0, 0)
        case 6: (xa, xb, xc, ya, yb, yc) = (0, -1, 1, 1, 0, 0)
        case 7: (xa, xb, xc, ya, yb, yc) = (0, -1, 1, -1, 0, 1)
        case 8: (xa, xb, xc, ya, yb, yc) = (0, 1, 0, -1, 0, 1)
        default: (xa, xb, xc, ya, yb, yc) = (1, 0, 0, 0, 1, 0)
        }
        return PdfMatrix(w * xa, -h * ya, -w * xb, h * yb, x + w * (xb + xc), y + h * (1 - yb - yc))
    }
}
