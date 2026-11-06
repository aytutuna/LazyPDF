import Foundation

// Twin of windows/LazyPDF.Core/Optimize/ImageKit.cs: what an image's colour space is made of, and plain pixel
// arithmetic over decoded samples, with the walk that measures where each image is placed.

enum ImageFamily { case gray, rgb, cmyk, indexed, lab, spot, unknown }

enum ImageKit {
    static func describe(_ document: PdfDocument, _ colorSpace: PdfObject?) -> (family: ImageFamily, components: Int) {
        switch document.resolve(colorSpace) {
        case let name as PdfName:
            switch name.value {
            case "DeviceGray", "G", "CalGray": return (.gray, 1)
            case "DeviceRGB", "RGB", "CalRGB": return (.rgb, 3)
            case "DeviceCMYK", "CMYK": return (.cmyk, 4)
            default: return (.unknown, 0)
            }
        case let array as PdfArray:
            guard let kind = document.resolve(array.items.first) as? PdfName else { break }
            switch kind.value {
            case "CalGray": return (.gray, 1)
            case "CalRGB": return (.rgb, 3)
            case "Lab": return (.lab, 3)
            case "Indexed", "I": return (.indexed, 1)
            case "Separation": return (.spot, 1)
            case "DeviceN":
                if array.items.count > 1, let names = document.resolve(array.items[1]) as? PdfArray { return (.spot, names.items.count) }
                return (.unknown, 0)
            case "ICCBased":
                var n = 0
                if array.items.count > 1, let profile = document.resolve(array.items[1]) as? PdfStream { n = document.integer(profile.dictionary, "N") ?? 0 }
                switch n {
                case 1: return (.gray, 1)
                case 3: return (.rgb, 3)
                case 4: return (.cmyk, 4)
                default: return (.unknown, 0)
                }
            case "DeviceGray", "DeviceRGB", "DeviceCMYK":
                return describe(document, kind)
            default:
                break
            }
        default:
            break
        }
        return (.unknown, 0)
    }

    /// The samples of an image at 8 bits each, rows packed; 16-bit samples keep their high byte, fewer bits are scaled to the full range.
    static func unpack(_ data: [UInt8], _ width: Int, _ height: Int, _ components: Int, _ bpc: Int) -> [UInt8] {
        let perRow = width * components
        var result = Array(repeating: UInt8(0), count: perRow * height)
        let rowBytes = (perRow * bpc + 7) / 8
        for y in 0..<height {
            let from = y * rowBytes
            if from >= data.count { break }
            let available = Swift.min(rowBytes, data.count - from)
            let to = y * perRow
            switch bpc {
            case 8:
                for i in 0..<Swift.min(perRow, available) { result[to + i] = data[from + i] }
            case 16:
                var i = 0
                while i < perRow && 2 * i < available {
                    result[to + i] = data[from + 2 * i]
                    i += 1
                }
            default:
                guard bpc == 1 || bpc == 2 || bpc == 4 else { return result }
                let max = (1 << bpc) - 1
                for i in 0..<perRow {
                    let bit = i * bpc
                    if bit / 8 >= available { break }
                    result[to + i] = UInt8(truncatingIfNeeded: ((Int(data[from + bit / 8]) >> (8 - bpc - bit % 8)) & max) * 255 / max)
                }
            }
        }
        return result
    }

    /// Shrinks 8-bit samples by averaging the source pixels each new pixel covers.
    static func shrink(_ source: [UInt8], _ width: Int, _ height: Int, _ components: Int, _ newWidth: Int, _ newHeight: Int) -> [UInt8] {
        var result = Array(repeating: UInt8(0), count: newWidth * newHeight * components)
        if source.count < width * height * components { return result }
        var sums = Array(repeating: 0, count: components)
        for y in 0..<newHeight {
            let y0 = y * height / newHeight
            let y1 = Swift.max(y0 + 1, (y + 1) * height / newHeight)
            for x in 0..<newWidth {
                let x0 = x * width / newWidth
                let x1 = Swift.max(x0 + 1, (x + 1) * width / newWidth)
                for c in 0..<components { sums[c] = 0 }
                for sy in y0..<y1 {
                    var at = (sy * width + x0) * components
                    for _ in x0..<x1 {
                        for c in 0..<components {
                            sums[c] += Int(source[at])
                            at += 1
                        }
                    }
                }
                let count = (y1 - y0) * (x1 - x0)
                let o = (y * newWidth + x) * components
                for c in 0..<components { result[o + c] = UInt8(truncatingIfNeeded: (sums[c] + count / 2) / count) }
            }
        }
        return result
    }

    static func luminance(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (299 * r + 587 * g + 114 * b + 500) / 1000)
    }
}

/// The lowest resolution an image XObject has anywhere it is painted, in pixels per inch along each side: the use that stretches it most decides how many pixels it needs.
final class Placement {
    var dpiX = Double.greatestFiniteMagnitude
    var dpiY = Double.greatestFiniteMagnitude
}

// Where each image is painted and how big: the real resolution is pixels over the placed size,
// which is the matrix scale times the page's /UserUnit points.
final class PlacedImages: OptimizeWalk {
    private(set) var found: [ObjectIdentifier: Placement] = [:]

    static func measure(_ document: PdfDocument) -> PlacedImages {
        let visitor = PlacedImages(document)
        visitor.walk()
        return visitor
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        guard let stream = image.stream, !image.isMask else { return }
        let across = hypot(image.matrix.a, image.matrix.b) * userUnit
        let down = hypot(image.matrix.c, image.matrix.d) * userUnit
        if across < 1e-6 || down < 1e-6 { return }
        let placement: Placement
        if let known = found[ObjectIdentifier(stream)] {
            placement = known
        } else {
            placement = Placement()
            found[ObjectIdentifier(stream)] = placement
        }
        placement.dpiX = Swift.min(placement.dpiX, Double(image.width) * 72 / across)
        placement.dpiY = Swift.min(placement.dpiY, Double(image.height) * 72 / down)
    }
}
