import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentWriter.cs: content stream bytes from operations: parsed ones written
// back, or new ones built with the small helpers below. Numbers are written the way `PdfNumber` writes them, at
// most six decimals with no exponent.

public final class ContentWriter {
    private var bytes: [UInt8] = []
    private var line = ""

    public init() {}

    public var length: Int { bytes.count }

    public func toArray() -> [UInt8] { bytes }

    /// The operations written out one to a line; parsing the result gives the same operators and operands.
    public static func write(_ operations: [ContentOperation]) -> [UInt8] {
        let writer = ContentWriter()
        for operation in operations { writer.add(operation) }
        return writer.toArray()
    }

    @discardableResult
    public func add(_ operation: ContentOperation) -> ContentWriter {
        if let image = operation.image {
            line.append("BI")
            for (key, value) in image.dictionary.entries {
                line.append(" ")
                PdfName(key).writeTo(&line)
                line.append(" ")
                value.writeTo(&line)
            }
            line.append("\nID\n")
            flush()
            bytes.append(contentsOf: image.data)
            line.append("\nEI\n")
            flush()
            return self
        }
        return op(operation.operator, operation.operands)
    }

    /// One operator with its operands.
    @discardableResult
    public func op(_ name: String, _ operands: [PdfObject]) -> ContentWriter {
        for operand in operands {
            operand.writeTo(&line)
            line.append(" ")
        }
        line.append(name)
        line.append("\n")
        flush()
        return self
    }

    @discardableResult
    public func op(_ name: String, _ numbers: Double...) -> ContentWriter {
        for n in numbers {
            line.append(PdfNumber(n).text)
            line.append(" ")
        }
        line.append(name)
        line.append("\n")
        flush()
        return self
    }

    private func flush() {
        if line.isEmpty { return }
        bytes.append(contentsOf: Latin1.bytes(line))
        line = ""
    }

    @discardableResult
    public func save() -> ContentWriter { op("q") }

    @discardableResult
    public func restore() -> ContentWriter { op("Q") }

    @discardableResult
    public func concat(_ m: PdfMatrix) -> ContentWriter { op("cm", m.a, m.b, m.c, m.d, m.e, m.f) }

    @discardableResult
    public func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ContentWriter { op("re", x, y, width, height) }

    @discardableResult
    public func moveTo(_ x: Double, _ y: Double) -> ContentWriter { op("m", x, y) }

    @discardableResult
    public func lineTo(_ x: Double, _ y: Double) -> ContentWriter { op("l", x, y) }

    @discardableResult
    public func curveTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) -> ContentWriter {
        op("c", x1, y1, x2, y2, x3, y3)
    }

    @discardableResult
    public func close() -> ContentWriter { op("h") }

    @discardableResult
    public func fill() -> ContentWriter { op("f") }

    @discardableResult
    public func fillEvenOdd() -> ContentWriter { op("f*") }

    @discardableResult
    public func stroke() -> ContentWriter { op("S") }

    @discardableResult
    public func fillAndStroke() -> ContentWriter { op("B") }

    @discardableResult
    public func endPath() -> ContentWriter { op("n") }

    /// Clips to the current path and ends it.
    @discardableResult
    public func clip() -> ContentWriter { op("W").op("n") }

    @discardableResult
    public func lineWidth(_ width: Double) -> ContentWriter { op("w", width) }

    @discardableResult
    public func dash(_ on: Double, _ off: Double) -> ContentWriter {
        op("d", [PdfArray([PdfNumber(on), PdfNumber(off)]), PdfNumber(0)])
    }

    @discardableResult
    public func fillGray(_ g: Double) -> ContentWriter { op("g", g) }

    @discardableResult
    public func fillRgb(_ r: Double, _ g: Double, _ b: Double) -> ContentWriter { op("rg", r, g, b) }

    @discardableResult
    public func fillCmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> ContentWriter { op("k", c, m, y, k) }

    @discardableResult
    public func strokeGray(_ g: Double) -> ContentWriter { op("G", g) }

    @discardableResult
    public func strokeRgb(_ r: Double, _ g: Double, _ b: Double) -> ContentWriter { op("RG", r, g, b) }

    @discardableResult
    public func strokeCmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> ContentWriter { op("K", c, m, y, k) }

    /// Selects the /ExtGState resource `name`.
    @discardableResult
    public func graphicsState(_ name: String) -> ContentWriter { op("gs", [PdfName(name)]) }

    @discardableResult
    public func beginText() -> ContentWriter { op("BT") }

    @discardableResult
    public func endText() -> ContentWriter { op("ET") }

    @discardableResult
    public func font(_ name: String, _ size: Double) -> ContentWriter { op("Tf", [PdfName(name), PdfNumber(size)]) }

    /// Moves to the start of the next line, offset from the start of the current one.
    @discardableResult
    public func moveText(_ x: Double, _ y: Double) -> ContentWriter { op("Td", x, y) }

    @discardableResult
    public func textMatrix(_ m: PdfMatrix) -> ContentWriter { op("Tm", m.a, m.b, m.c, m.d, m.e, m.f) }

    @discardableResult
    public func textRenderMode(_ mode: Int) -> ContentWriter { op("Tr", Double(mode)) }

    @discardableResult
    public func charSpacing(_ spacing: Double) -> ContentWriter { op("Tc", spacing) }

    @discardableResult
    public func wordSpacing(_ spacing: Double) -> ContentWriter { op("Tw", spacing) }

    /// Shows text already encoded for the current font, as a hex string.
    @discardableResult
    public func show(_ encoded: [UInt8]) -> ContentWriter { op("Tj", [PdfString(bytes: encoded, isHex: true)]) }

    /// Shows the line of text in `font` set in `size`, in display order. A shaper's offsets and advances that differ from
    /// the font's become `TJ` adjustments and `Ts` rises; a line whose glyphs do not map one to one to its characters is
    /// wrapped in marked content with /ActualText, so that copying gives the logical text.
    @discardableResult
    public func show(_ font: PdfDrawFont, _ text: String, _ size: Double) -> ContentWriter {
        show(font, font.shaped(text), text, size)
    }

    /// Shows a run whose direction the layout has already resolved.
    @discardableResult
    func showRun(_ font: PdfDrawFont, _ text: String, _ rightToLeft: Bool, _ size: Double) -> ContentWriter {
        show(font, font.run(text, rightToLeft), text, size)
    }

    private func show(_ font: PdfDrawFont, _ line: ShapedLine?, _ text: String, _ size: Double) -> ContentWriter {
        guard let line else { return show(font.encode(text)) }
        if line.needsActualText {
            var bytes: [UInt8] = [0xFE, 0xFF]
            for unit in line.actualText.utf16 {
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
                bytes.append(UInt8(truncatingIfNeeded: unit))
            }
            let properties = PdfDictionary()
            properties["ActualText"] = PdfString(bytes: bytes, isHex: true)
            op("BDC", [PdfName("Span"), properties])
        }

        var items: [PdfObject] = []
        var codes: [UInt8] = []
        var adjusted = false
        var carry = 0.0, rise = 0.0
        func rounded(_ value: Double) -> Double { (value * 1000).rounded(.toNearestOrEven) / 1000 }
        func adjust() {
            carry = rounded(carry)
            if carry == 0 { return }
            if !codes.isEmpty { items.append(PdfString(bytes: codes, isHex: true)) }
            codes.removeAll()
            items.append(PdfNumber(carry))
            carry = 0
            adjusted = true
        }
        func closeShow() {
            if !codes.isEmpty { items.append(PdfString(bytes: codes, isHex: true)) }
            codes.removeAll()
            if !items.isEmpty { op(adjusted ? "TJ" : "Tj", [adjusted ? PdfArray(items) : items[0]]) }
            items = []
            adjusted = false
        }

        for entry in line.glyphs {
            let glyph = entry.shaped
            let lift = rounded(glyph.yOffset * size / 1000)
            if lift != rise {
                closeShow()
                op("Ts", lift)
                rise = lift
            }
            // A TJ number moves the pen left by that much, so the glyph is drawn after -xOffset and the pen then put where the shaper wants it.
            carry -= glyph.xOffset
            adjust()
            codes.append(contentsOf: font.codeOf(line, entry))
            let drift = font.codeWidth(glyph.glyph) - glyph.advance
            carry += glyph.xOffset + (abs(drift) > 0.5 ? drift : 0)
        }
        closeShow()
        if rise != 0 { op("Ts", 0) }
        return line.needsActualText ? endMarked() : self
    }

    /// Paints the /XObject resource `name`.
    @discardableResult
    public func paint(_ name: String) -> ContentWriter { op("Do", [PdfName(name)]) }

    /// Paints an image or form so that its unit square fills the matrix's parallelogram.
    @discardableResult
    public func paint(_ name: String, _ placement: PdfMatrix) -> ContentWriter {
        save().concat(placement).paint(name).restore()
    }

    @discardableResult
    public func beginMarked(_ tag: String) -> ContentWriter { op("BMC", [PdfName(tag)]) }

    /// Opens marked content with an inline property dictionary holding /MCID.
    @discardableResult
    public func beginMarked(_ tag: String, _ mcid: Int) -> ContentWriter {
        let properties = PdfDictionary()
        properties["MCID"] = PdfNumber(mcid)
        return op("BDC", [PdfName(tag), properties])
    }

    @discardableResult
    public func endMarked() -> ContentWriter { op("EMC") }

    /// The bytes as they are, for an operator the helpers do not cover.
    @discardableResult
    public func raw(_ text: String) -> ContentWriter {
        line.append(text)
        // Not hasSuffix: "\r\n" is one Character in Swift.
        if text.unicodeScalars.last != "\n" { line.append("\n") }
        flush()
        return self
    }
}
