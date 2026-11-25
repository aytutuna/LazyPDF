import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditFixtures.cs: the same files. Arial is EditFont here.

enum EditFixtures {
    static func arial() -> [UInt8] { EditFont.bytes }

    /// A page with one line drawn in a Type0 font that holds just the letters of the line.
    static func embeddedLine(_ line: String) throws -> [UInt8] {
        let scratch = try PdfDocument.open(TestPdf.simple(1))
        let draw = try XCTUnwrap(try PdfFontEmbedder(scratch, EditArialSource()).add("Arial", .regular, [line], embed: true))
        let content = ContentWriter().beginText().font("F1", 12).moveText(10, 100).show(draw.encode(line)).endText().toArray()
        return try onePage(scratch, draw.reference, content)
    }

    private static func onePage(_ scratch: PdfDocument, _ font: PdfReference, _ content: [UInt8]) throws -> [UInt8] {
        let page = scratch.pages[0]
        let resources = PdfDictionary()
        let fonts = PdfDictionary()
        fonts["F1"] = font
        resources["Font"] = fonts
        page.dictionary["Resources"] = resources
        page.dictionary["Contents"] = try scratch.add(PdfStream(PdfDictionary(), data: content))
        return try scratch.saveRewrite()
    }

    /// A page with one line in a Type0 font holding the whole of the font under its plain name, so it has no subset tag.
    static func fullCidLine(_ line: String) throws -> [UInt8] {
        let font = arial()
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(font))
        let scratch = try PdfDocument.open(TestPdf.simple(1))
        var codes: [Int: Int] = [:]
        for scalar in line.unicodeScalars { codes[Int(scalar.value)] = tt.glyphForCodePoint(Int(scalar.value)) }
        let program = PdfDictionary()
        program["Filter"] = PdfName("FlateDecode")
        program["Length1"] = PdfNumber(font.count)
        let file = try scratch.add(PdfStream(program, data: PdfFilterEncoders.flate(font)))
        let descriptor = PdfDictionary()
        descriptor["Type"] = PdfName("FontDescriptor")
        descriptor["FontName"] = PdfName("Arial")
        descriptor["Flags"] = PdfNumber(32)
        descriptor["FontBBox"] = PdfArray([PdfNumber(-665), PdfNumber(-325), PdfNumber(2000), PdfNumber(1006)])
        descriptor["ItalicAngle"] = PdfNumber(0)
        descriptor["Ascent"] = PdfNumber(905)
        descriptor["Descent"] = PdfNumber(-212)
        descriptor["CapHeight"] = PdfNumber(716)
        descriptor["StemV"] = PdfNumber(80)
        descriptor["FontFile2"] = file
        var widths: [PdfObject] = []
        for (_, gid) in codes.sorted(by: { $0.value < $1.value }) {
            widths.append(PdfNumber(gid))
            widths.append(PdfArray([PdfNumber((Double(tt.getAdvance(gid)) * 1000.0 / Double(tt.unitsPerEm)).rounded(.toNearestOrEven))]))
        }
        let info = PdfDictionary()
        info["Registry"] = PdfString(bytes: Array("Adobe".utf8), isHex: false)
        info["Ordering"] = PdfString(bytes: Array("Identity".utf8), isHex: false)
        info["Supplement"] = PdfNumber(0)
        let cid = PdfDictionary()
        cid["Type"] = PdfName("Font")
        cid["Subtype"] = PdfName("CIDFontType2")
        cid["BaseFont"] = PdfName("Arial")
        cid["CIDSystemInfo"] = info
        cid["FontDescriptor"] = try scratch.add(descriptor)
        cid["DW"] = PdfNumber(1000)
        cid["W"] = PdfArray(widths)
        cid["CIDToGIDMap"] = PdfName("Identity")
        let cmap = try ToUnicodeCMap.write(codes.map { (key: $0.value, value: String(Unicode.Scalar(UInt32($0.key)) ?? "?")) })
        let toUnicode = PdfDictionary()
        toUnicode["Filter"] = PdfName("FlateDecode")
        let type0 = PdfDictionary()
        type0["Type"] = PdfName("Font")
        type0["Subtype"] = PdfName("Type0")
        type0["BaseFont"] = PdfName("Arial")
        type0["Encoding"] = PdfName("Identity-H")
        type0["DescendantFonts"] = PdfArray([try scratch.add(cid)])
        type0["ToUnicode"] = try scratch.add(PdfStream(toUnicode, data: PdfFilterEncoders.flate(cmap)))
        var encoded: [UInt8] = []
        for scalar in line.unicodeScalars {
            let gid = codes[Int(scalar.value)] ?? 0
            encoded += [UInt8(truncatingIfNeeded: gid >> 8), UInt8(truncatingIfNeeded: gid)]
        }
        let content = ContentWriter().beginText().font("F1", 12).moveText(10, 100).show(encoded).endText().toArray()
        return try onePage(scratch, try scratch.add(type0), content)
    }
}
