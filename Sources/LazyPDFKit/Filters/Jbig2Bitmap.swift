import Foundation

// Twin of windows/LazyPDF.Core/Filters/Jbig2Bitmap.cs: the budget of a JBIG2 decode and its bilevel bitmaps.

/// What one JBIG2 decode may allocate, so that a hostile stream cannot make the decoder run out of memory.
final class Jbig2Budget {
    /// The pixels of every bitmap made during one decode, whether still alive or not.
    private var total = 3 * PdfImageSamples.maxPixels

    /// The globals of an image may be shared by many; they make symbols and tables, not pages.
    func forGlobals() {
        total = min(total, 1 << 26)
        work = min(work, 1 << 27)
    }

    /// The budget of the image's own segments: the most there is, or tied to the size of its picture.
    func forImage(_ fitPixels: Int) {
        total = 3 * PdfImageSamples.maxPixels
        work = 1 << 29
        if fitPixels > 0 { fit(fitPixels) }
    }

    /// With the pixels of the picture the page is fitted to, what a decode may make is a multiple of that and a little more:
    /// a dictionary that says 1 by 1 does not get a page of millions of pixels made for it and cut down.
    func fit(_ size: Int) {
        // Past this the other limits are the smaller ones; the cap keeps the products below from overflowing.
        let fitPixels = min(size, 1 << 40)
        total = min(total, 16 * fitPixels + (1 << 24))
        // Enough for a page of symbols however small, and for drawing over the picture many times.
        work = min(work, 32 * fitPixels + (1 << 26))
    }

    /// The pixels of the symbols and patterns that stay around for later segments.
    private var kept = 1 << 26

    /// The pixels that symbols and refinements may be drawn or coded over, all together.
    private var work = 1 << 29

    static func tooBig() -> PdfReadException { FilterBuffer.tooBig() }

    /// The arrays a segment makes whatever it holds, counted as pixels.
    func fixed(_ bytes: Int) throws { try charge(bytes, 1) }

    func charge(_ width: Int, _ height: Int) throws {
        if width < 0 || height < 0 { throw Jbig2Budget.tooBig() }
        // A bitmap with no columns or no rows still costs the rows or columns that a loop over it walks.
        // Sizes come from 32-bit fields, so the product of two of them fits.
        let pixels = max(width, 1) * max(height, 1)
        if pixels > PdfImageSamples.maxPixels || pixels > total { throw Jbig2Budget.tooBig() }
        total -= pixels
    }

    func chargeWork(_ pixels: Int) throws {
        if pixels > work { throw Jbig2Budget.tooBig() }
        work -= pixels
    }

    func keep(_ pixels: Int) throws {
        if pixels > kept { throw Jbig2Budget.tooBig() }
        kept -= pixels
    }
}

/// A bilevel image as one byte, 0 or 1, per pixel; 1 is black. Rows follow each other without padding.
final class Jbig2Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(_ width: Int, _ height: Int, _ budget: Jbig2Budget) throws {
        try budget.charge(width, height)
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    func fill(_ value: UInt8) {
        for i in 0..<pixels.count { pixels[i] = value }
    }

    /// Combines `source` with this bitmap with its top left corner at (x, y), the parts outside this bitmap
    /// dropped. The operators are those of 7.4.1.5: 0 OR, 1 AND, 2 XOR, 3 XNOR, 4 REPLACE.
    func compose(_ source: Jbig2Bitmap, _ x: Int, _ y: Int, _ op: Int) {
        let left = min(source.width, max(0, -x)), top = min(source.height, max(0, -y))
        let right = min(source.width, width - x), bottom = min(source.height, height - y)
        if top >= bottom || left >= right { return }
        // Taken out of the object so that the writes below do not copy the array.
        var dest = pixels
        pixels = []
        defer { pixels = dest }
        let width = self.width
        source.pixels.withUnsafeBufferPointer { src in
            for sy in top..<bottom {
                let from = sy * source.width
                let to = (y + sy) * width + x
                for sx in left..<right {
                    let s = src[from + sx]
                    let d = dest[to + sx]
                    switch op {
                    case 0: dest[to + sx] = d | s
                    case 1: dest[to + sx] = d & s
                    case 2: dest[to + sx] = d ^ s
                    case 3: dest[to + sx] = 1 ^ d ^ s
                    default: dest[to + sx] = s
                    }
                }
            }
        }
    }

    /// The columns from `x` to `x` + `width` of every row.
    func columns(_ x: Int, _ width: Int, _ budget: Jbig2Budget) throws -> Jbig2Bitmap {
        let part = try Jbig2Bitmap(width, height, budget)
        for row in 0..<height {
            let from = row * self.width + x
            let to = row * width
            for i in 0..<width { part.pixels[to + i] = pixels[from + i] }
        }
        return part
    }
}
