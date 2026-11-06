import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactDepthTests.cs: the same cases. The interpreter enters 20 forms deep; the
// 20th is the last one it reads and what it calls is out of sight, so the page becomes a picture.

final class RedactDepthTests: XCTestCase {
    private let near = PdfRect(90, 90, 200, 120)

    // Forms 6 to 25 call the next one; form 25 shows "near" and calls form 26, which holds the secret.
    private func chain() throws -> PdfDocument {
        try RedactionKit.page("/F6 Do", "/XObject <</F6 6 0 R>>") { pdf in
            for i in 6..<25 {
                pdf.stream(i, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</F\(i + 1) \(i + 1) 0 R>>>>", "/F\(i + 1) Do")
            }
            pdf.stream(25, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</F26 26 0 R>>>>", "BT /F1 12 Tf 100 100 Td (near) Tj ET /F26 Do")
            pdf.stream(26, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 300 Td (ZQXDEEPSECRET) Tj ET")
        }
    }

    func test_formsNestedPastTheDepthMakeThePagePicture() throws {
        let document = try chain()
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXDEEPSECRET", "near")
    }

    func test_contentItemOfAPageThatBecamePictureLeavesTheTree() throws {
        let document = try chain()
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        let top = PdfDictionary()
        let figure = PdfDictionary()
        let rootRef = try document.add(root)
        let topRef = try document.add(top)
        let figureRef = try document.add(figure)
        root["K"] = PdfArray([topRef])
        top["Type"] = PdfName("StructElem")
        top["S"] = PdfName("Document")
        top["P"] = rootRef
        top["K"] = PdfArray([figureRef])
        figure["Type"] = PdfName("StructElem")
        figure["S"] = PdfName("Figure")
        figure["P"] = topRef
        figure["Pg"] = document.pages[0].reference
        let item = PdfDictionary()
        item["Type"] = PdfName("MCR")
        item["Pg"] = document.pages[0].reference
        item["Stm"] = PdfReference(25, 0)
        item["MCID"] = PdfNumber(0)
        figure["K"] = item
        figure["Alt"] = PdfText.toObject("ZQXALT")
        document.catalog["StructTreeRoot"] = rootRef
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.contains(0))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXALT"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXDEEPSECRET"))
    }
}
