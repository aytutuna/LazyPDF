import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionGlyphs.cs: the glyph procedures of a Type 3 font. A procedure paints where
// it pleases (ISO 32000-1 9.6.5), so the font is understood only when every procedure paints shapes and bitmaps and nothing
// that leads further (forms, shadings, patterns, text), and a glyph is taken out when its ink meets a mark, wherever the box
// of the glyph is.

enum RedactionGlyphs {
    private static let maxProcedure = 16 << 20

    private static let maxProcedures = 4096

    // Wider than any glyph is: the box the scan tests runs from the origin by the width, and a larger one moves its core off the ink (9.7.4.3).
    private static let maxWidth = 2000.0

    // A line or a rectangle with no extent is a hairline to a viewer, so it gets a width of its own (em) to be tested.
    private static let hairline = 0.001

    /// Whether the widths of the font are the ones a viewer uses. The advance follows /Widths (9.6.2.1) or /W and /DW
    /// (9.7.4.3), within /FirstChar and /LastChar; past them, or with none, a viewer takes the metrics of its own
    /// substitute, which the scan cannot know unless the font is one of the standard 14 or carries its program.
    static func measured(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        if document.name(dictionary, "Subtype") == "Type0" { return composite(document, dictionary) }
        if let missing = document.number(document.dict(dictionary, "FontDescriptor"), "MissingWidth"), !fine(missing) { return false }
        if !dictionary.containsKey("Widths") {
            let font = PdfFont.get(document, dictionary)
            return !font.isType3 && (font.isEmbedded || Standard14.find(font.name) != nil)
        }
        guard let widths = document.array(dictionary, "Widths"), let first = document.integer(dictionary, "FirstChar"),
              let last = document.integer(dictionary, "LastChar") else { return false }
        // The C# subtracts in long without a check; a wrapped value is no count of the widths either.
        return first >= 0 && last <= 255 && widths.items.count == last &- first &+ 1
            && widths.items.allSatisfy { w in (document.resolve(w) as? PdfNumber).map { fine($0.value) } ?? false }
    }

    private static func fine(_ width: Double) -> Bool { width >= 0 && width <= maxWidth }

    private static func composite(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        guard let descendants = document.array(dictionary, "DescendantFonts"), descendants.items.count == 1,
              let cid = document.resolve(descendants.items[0]) as? PdfDictionary else { return false }
        if cid.containsKey("DW") && !fine(document.number(cid, "DW") ?? -1) { return false }
        if !cid.containsKey("W") { return true }
        guard let list = document.array(cid, "W") else { return false }
        let items = list.items.map { document.resolve($0) }
        // c [w1 w2 ...] or c1 c2 w (9.7.4.3)
        var i = 0
        while i < items.count {
            if i + 1 >= items.count || !(items[i] is PdfNumber) { return false }
            if let run = items[i + 1] as? PdfArray {
                if !run.items.allSatisfy({ w in (document.resolve(w) as? PdfNumber).map { fine($0.value) } ?? false }) { return false }
                i += 2
            } else if i + 2 < items.count, items[i + 1] is PdfNumber, let width = items[i + 2] as? PdfNumber, fine(width.value) {
                i += 3
            } else {
                return false
            }
        }
        return true
    }

    // Every entry of /CharProcs counts, not only those the encoding reaches: PdfFont stops reading /Differences at a limit a viewer may not have.
    static func plain(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        guard let procedures = document.dict(dictionary, "CharProcs") else { return true }
        if procedures.count > maxProcedures { return false }
        // PdfFont ignores a matrix that does not scale x, so the ink would be measured in another space than the one drawn.
        if dictionary.containsKey("FontMatrix") {
            guard RedactionSyntax.isMatrix(document, dictionary, "FontMatrix"),
                  let matrix = PdfMatrix.fromArray(document.array(dictionary, "FontMatrix"), { document.resolve($0) }), matrix.a != 0 else { return false }
        }
        // PdfFont stops at this many items of /Differences; a viewer that reads on picks other procedures than the ones measured.
        if let differences = document.array(document.dict(dictionary, "Encoding"), "Differences"), differences.items.count > maxProcedures { return false }
        let font = PdfFont.get(document, dictionary)
        return procedures.entries.allSatisfy { e in
            guard let procedure = document.resolve(e.value) as? PdfStream else { return true }
            return ink(document, font, procedure) != nil
        }
    }

    static func procedure(_ document: PdfDocument, _ font: PdfFont, _ code: Int) -> PdfStream? {
        guard let name = font.glyphNameOf(code), let procedures = document.dict(font.dictionary, "CharProcs") else { return nil }
        return document.resolve(procedures[name]) as? PdfStream
    }

    // The ink of a procedure in em, a point at the origin when it paints nothing; nil when it holds more than a plain glyph does.
    static func ink(_ document: PdfDocument, _ font: PdfFont, _ procedure: PdfStream) -> PdfRect? {
        let data: [UInt8]
        do {
            data = try document.data(procedure, maxProcedure)
        } catch {
            // Only a PdfReadException comes out of a stream; whatever it is, a procedure that does not read is not plain.
            return nil
        }
        let operations = ContentParser.parse(data)
        if !RedactionSyntax.whole(data, operations) { return nil }
        for op in operations {
            if !RedactionSyntax.valid(op) || !RedactionSyntax.inGlyph(op.operator) { return nil }
            if op.operator == "BI" && !RedactionSyntax.fits(document, op, data, { _ in nil }) { return nil }
        }
        let ink = InkVisitor()
        // A procedure is not a form: a /Matrix or /BBox on its stream means nothing, so it is run without the keys.
        let interpreter = ContentInterpreter(document)
        interpreter.run(PdfStream(PdfDictionary(), data: data), ink, font.fontMatrix)
        return interpreter.isTruncated ? nil : ink.box
    }

    private final class InkVisitor: ContentVisitor {
        private var left = Double.greatestFiniteMagnitude, bottom = Double.greatestFiniteMagnitude
        private var right = -Double.greatestFiniteMagnitude, top = -Double.greatestFiniteMagnitude

        var box: PdfRect {
            if left > right { return PdfRect(0, 0, 0, 0) }
            return PdfRect(left - (left == right ? RedactionGlyphs.hairline : 0), bottom - (bottom == top ? RedactionGlyphs.hairline : 0),
                           right + (left == right ? RedactionGlyphs.hairline : 0), top + (bottom == top ? RedactionGlyphs.hairline : 0))
        }

        private func add(_ box: PdfRect) {
            left = nanMin(left, box.left)
            bottom = nanMin(bottom, box.bottom)
            right = nanMax(right, box.right)
            top = nanMax(top, box.top)
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if path.fill || path.stroke || path.clips { add(path.inkBounds) }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) { add(image.bounds) }
    }
}
