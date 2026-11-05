import Foundation

// Twin of windows/LazyPDF.Core/Export/PngWriter.cs: a PNG encoder for 8-bit pixels: gray, RGB or RGBA, whichever the
// pixels need, rows filtered adaptively.

public enum PngWriter {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Throws `ArgumentException` when the size is not positive or does not fit the data.
    public static func encode(_ image: PdfRgbaImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 4)
        if width < 1 || height < 1 || areaOverflow || bytesOverflow || bytes != image.rgba.count {
            throw ArgumentException("The pixel data does not fit the size.")
        }
        let rgba = image.rgba
        var opaque = true, gray = true
        var i = 0
        while i < rgba.count {
            if rgba[i + 3] != 255 { opaque = false }
            if rgba[i] != rgba[i + 1] || rgba[i] != rgba[i + 2] { gray = false }
            i += 4
        }
        let channels = gray && opaque ? 1 : opaque ? 3 : 4
        let colorType: UInt8 = channels == 1 ? 0 : channels == 3 ? 2 : 6

        let stride = width * channels
        var pixels = [UInt8](repeating: 0, count: height * stride)
        for y in 0..<height {
            for x in 0..<width {
                let s = (y * width + x) * 4, d = y * stride + x * channels
                pixels[d] = rgba[s]
                if channels == 1 { continue }
                pixels[d + 1] = rgba[s + 1]
                pixels[d + 2] = rgba[s + 2]
                if channels == 4 { pixels[d + 3] = rgba[s + 3] }
            }
        }

        var raw: [UInt8] = []
        raw.reserveCapacity(height * (stride + 1))
        var filtered = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            var bestType: UInt8 = 0
            var bestCost = Int.max
            for type in 0...4 {
                filter(type, pixels, y * stride, stride, y > 0, channels, &filtered)
                var cost = 0
                for b in filtered { cost += b < 128 ? Int(b) : 256 - Int(b) }
                if cost >= bestCost { continue }
                bestCost = cost
                bestType = UInt8(type)
                swap(&filtered, &best)
            }
            raw.append(bestType)
            raw += best
        }

        var png = signature
        var header = [UInt8](repeating: 0, count: 13)
        writeInt(&header, 0, width)
        writeInt(&header, 4, height)
        header[8] = 8
        header[9] = colorType
        chunk(&png, Array("IHDR".utf8), header)
        chunk(&png, Array("IDAT".utf8), PdfFilterEncoders.flate(raw, .optimal))
        chunk(&png, Array("IEND".utf8), [])
        return png
    }

    // ISO/IEC 15948 9.2 (the five filter types); the row above is the one before `start`, and the first row has none.
    private static func filter(_ type: Int, _ pixels: [UInt8], _ start: Int, _ stride: Int, _ hasAbove: Bool, _ bpp: Int, _ output: inout [UInt8]) {
        for i in 0..<stride {
            let a = i >= bpp ? Int(pixels[start + i - bpp]) : 0
            let b = hasAbove ? Int(pixels[start - stride + i]) : 0
            let c = i >= bpp && hasAbove ? Int(pixels[start - stride + i - bpp]) : 0
            let predicted: Int
            switch type {
            case 0: predicted = 0
            case 1: predicted = a
            case 2: predicted = b
            case 3: predicted = (a + b) / 2
            default: predicted = paeth(a, b, c)
            }
            output[i] = UInt8(truncatingIfNeeded: Int(pixels[start + i]) - predicted)
        }
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    private static func chunk(_ output: inout [UInt8], _ type: [UInt8], _ body: [UInt8]) {
        var length = [UInt8](repeating: 0, count: 4)
        writeInt(&length, 0, body.count)
        output += length
        output += type
        output += body
        let crc = ExportZip.crc32(body, ExportZip.crc32(type))
        writeInt(&length, 0, Int(crc))
        output += length
    }

    private static func writeInt(_ buffer: inout [UInt8], _ at: Int, _ value: Int) {
        buffer[at] = UInt8(truncatingIfNeeded: value >> 24)
        buffer[at + 1] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[at + 2] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[at + 3] = UInt8(truncatingIfNeeded: value)
    }
}
