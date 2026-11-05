import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextTestPdf.cs. The C# test classes import its methods with `using static`;
// here they inherit them from `TextTestCase`, which forwards to `TextTestPdf`.

typealias TextMap = [(Int, String)]

enum TextTestPdf {
    /// A Type 1 font that is half an em wide everywhere, so glyph positions are easy to work out. The text of a code is
    /// given as UTF-16 units, for the ones a Swift String cannot hold (half a pair).
    static func font(_ pdf: TestPdf, _ number: Int, units map: [(Int, [UInt16])] = []) {
        let widths = [String](repeating: "500", count: 256).joined(separator: " ")
        pdf.obj(number, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 0 /LastChar 255 /Widths [\(widths)] /ToUnicode \(number + 1) 0 R>>")
        var all: [(code: Int, text: [UInt16])] = []
        for (code, text) in map { all.append((code, text)) }
        for c in 32..<127 where !all.contains(where: { $0.code == c }) { all.append((c, [UInt16(c)])) }
        var cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange "
        cmap += "\(all.count) beginbfchar "
        for (code, text) in all {
            cmap += "<\(String(format: "%02lX", code))> <\(text.map { String(format: "%04X", $0) }.joined())> "
        }
        cmap += "endbfchar endcmap"
        pdf.stream(number + 1, "", cmap)
    }

    static func units(_ map: TextMap) -> [(Int, [UInt16])] { map.map { ($0.0, Array($0.1.utf16)) } }

    /// One page of 600 by 800 points whose font /F1 is `font` (object 5).
    static func page(_ content: String, _ pageEntries: String = "", _ map: TextMap = []) throws -> PdfDocument {
        try page(content, "/Font <</F1 5 0 R>>", pageEntries) { pdf in font(pdf, 5, units: units(map)) }
    }

    static func page(_ content: String, _ resources: String, _ pageEntries: String, _ objects: (TestPdf) -> Void) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>> \(pageEntries)>>")
        pdf.stream(4, "", content)
        objects(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    static func text(_ content: String, _ pageEntries: String = "", _ map: TextMap = []) throws -> TextPage {
        let document = try page(content, pageEntries, map)
        return TextPage.create(document, document.pages[0])
    }

    /// A number as .NET writes it: no ".0" on a whole one.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
    }

    /// A one with `zeros` zeros: PDF has no exponent notation, so a huge number is written out.
    static func big(_ zeros: Int) -> String { "1" + String(repeating: "0", count: zeros) }

    /// A line at the given point in /F1 at size 10 unless told otherwise: every glyph is half the size wide.
    static func line(_ x: Double, _ y: Double, _ text: String, _ size: Double = 10) -> String {
        "BT /F1 \(number(size)) Tf \(number(x)) \(number(y)) Td (\(text)) Tj ET\n"
    }
}

class TextTestCase: XCTestCase {
    func text(_ content: String, _ pageEntries: String = "", _ map: (Int, String)...) throws -> TextPage {
        try TextTestPdf.text(content, pageEntries, map)
    }

    func page(_ content: String, _ pageEntries: String = "", _ map: (Int, String)...) throws -> PdfDocument {
        try TextTestPdf.page(content, pageEntries, map)
    }

    func page(_ content: String, _ resources: String, _ pageEntries: String, _ objects: (TestPdf) -> Void) throws -> PdfDocument {
        try TextTestPdf.page(content, resources, pageEntries, objects)
    }

    func font(_ pdf: TestPdf, _ number: Int, _ map: (Int, String)...) {
        TextTestPdf.font(pdf, number, units: TextTestPdf.units(map))
    }

    func line(_ x: Double, _ y: Double, _ text: String, _ size: Double = 10) -> String { TextTestPdf.line(x, y, text, size) }
}
