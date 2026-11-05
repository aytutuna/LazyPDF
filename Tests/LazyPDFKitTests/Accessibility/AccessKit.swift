import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessKit.cs: small files for the accessibility tests. The C# also reads
// text and saved files with PdfPig (`PigText`, and the check in `Reopen`); those have no twin. Sizes and positions are ints,
// as every caller passes whole numbers and a Double would print as 72.0.

enum AccessKit {
    /// Object numbers after the pages' own: fonts F1 (Helvetica) and F2 (Helvetica-Bold), a 2 by 2 gray image Im1.
    static func firstFree(_ pages: Int) -> Int { 6 + 2 * pages }

    /// A file of `pages` pages 612 by 792 whose content is `content`(i); page i is object 3 + i and its content stream
    /// 3 + pages + i. `more` adds objects from `firstFree` on.
    static func build(_ pages: Int, _ content: (Int) -> String, catalog: String = "", pageEntries: String = "",
                      more: ((TestPdf) -> Void)? = nil, fontEntries: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        let kids = (0..<pages).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 612 792]>>")
        let f1 = 3 + 2 * pages, f2 = f1 + 1, image = f1 + 2
        for i in 0..<pages {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + pages + i) 0 R /Resources <</Font <</F1 \(f1) 0 R /F2 \(f2) 0 R \(fontEntries)>> /XObject <</Im1 \(image) 0 R>>>> \(pageEntries)>>")
        }
        for i in 0..<pages { pdf.stream(3 + pages + i, "", content(i)) }
        pdf.obj(f1, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(f2, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>")
        pdf.stream(image, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 80, 160, 255])
        more?(pdf)
        return pdf.finish()
    }

    static func text(_ x: Int, _ y: Int, _ text: String, _ size: Int = 11, bold: Bool = false) -> String {
        "BT /\(bold ? "F2" : "F1") \(size) Tf \(x) \(y) Td (\(text)) Tj ET\n"
    }

    /// A page of a report: running header and footer, a rule, a heading, two paragraphs, a bullet list, a table and a picture.
    static func reportPage(_ index: Int) -> String {
        var s = ""
        s += "q 0.8 g 72 745 468 1 re f Q\n"
        s += text(72, 760, "ACME Quarterly Report", 9)
        s += text(72, 700, "Introduction", 20, bold: true)
        s += "BT /F1 11 Tf 72 672 Td (This is the first paragraph of page \(index + 1). It has enough words) Tj 0 -14 Td (to fill two lines of the body text.) Tj ET\n"
        s += text(72, 620, "A second paragraph follows after a clear gap.")
        let items = ["First", "Second", "Third"]
        for i in 0..<3 {
            s += "BT /F1 11 Tf 72 \(580 - 16 * i) Td <95> Tj 18 0 Td (\(items[i]) item) Tj ET\n"
        }
        let table = [["Name", "Count", "Price"], ["Apples", "12", "3.50"], ["Pears", "7", "4.25"]]
        for r in 0..<table.count {
            for c in 0..<3 { s += text(72 + 150 * c, 500 - 16 * r, table[r][c], 11, bold: r == 0) }
        }
        s += "q 100 0 0 100 72 340 cm /Im1 Do Q\n"
        s += text(290, 30, "Page \(index + 1)", 9)
        return s
    }

    static func report(_ pages: Int = 3) -> [UInt8] { build(pages, reportPage) }

    static func plain(_ document: PdfDocument, _ page: Int) -> String {
        TextPage.create(document, document.pages[page]).text
    }

    /// The marked-content sequences of a page's content: tag and /MCID (-1 for none), in order, nesting ignored.
    static func sequences(_ document: PdfDocument, _ page: Int) -> [(tag: String, mcid: Int)] {
        var found: [(tag: String, mcid: Int)] = []
        for op in ContentParser.parse(document.pages[page].contents()) {
            if op.operator == "BMC", let a = op.operands.first as? PdfName { found.append((a.value, -1)) }
            if op.operator == "BDC", let b = op.operands.first as? PdfName {
                var mcid = -1
                if op.operands.count > 1, let d = op.operands[1] as? PdfDictionary, let n = (d["MCID"] as? PdfNumber)?.integer { mcid = n }
                found.append((b.value, mcid))
            }
        }
        return found
    }

    /// Balanced BMC/BDC and EMC, in every stream of the page.
    static func isBalanced(_ document: PdfDocument, _ page: Int) -> Bool {
        var depth = 0
        for op in ContentParser.parse(document.pages[page].contents()) {
            if op.operator == "BMC" || op.operator == "BDC" {
                depth += 1
            } else if op.operator == "EMC" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    static func reopen(_ document: PdfDocument, rewrite: Bool) throws -> PdfDocument {
        let bytes = rewrite ? try document.saveRewrite() : try document.saveIncremental()
        return try PdfDocument.open(bytes)
    }

    static func find(_ tree: StructureTree, _ type: String) -> StructElement? {
        tree.elements.first { $0.type == type }
    }
}
