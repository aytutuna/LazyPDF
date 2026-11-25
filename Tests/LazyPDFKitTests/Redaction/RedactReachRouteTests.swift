import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactReachRouteTests.cs: the same cases. The ways back into a form besides Do,
// each of which makes the page a picture: a font chosen by a graphics state, the mask of a shading pattern, a font name with a
// stray operand.

final class RedactReachRouteTests: XCTestCase {
    private let near = PdfRect(90, 90, 200, 120)
    private let shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET"
    private let type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</b 9 0 R>> "
        + "/Encoding <</Type /Encoding /Differences [98 /b]>> /FirstChar 98 /LastChar 98 /Widths [1000] /Resources <</XObject <</Fm 6 0 R>>>>>>"

    private func form(_ resources: String) -> String { "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> \(resources)>>" }

    private func assertGone(_ document: PdfDocument) throws {
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }

    func test_formReachedAgainThroughAFontOfAGraphicsStateIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/ExtGState <</G 7 0 R>>"), self.shows + " /G gs BT 300 300 Td (b) Tj ET")
            pdf.obj(7, "<</Type /ExtGState /Font [8 0 R 12]>>")
            pdf.obj(8, self.type3)
            pdf.stream(9, "", "1000 0 d0 /Fm Do")
        }
        try assertGone(document)
    }

    func test_formReachedAgainThroughTheMaskOfAShadingPatternIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/Pattern <</SP 7 0 R>>"), self.shows + " /Pattern cs /SP scn 300 300 5 5 re f")
            pdf.obj(7, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>>> "
                + "/ExtGState <</SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>>>")
            pdf.stream(8, self.form("/XObject <</Fm 6 0 R>>") + " /Group <</S /Transparency>>", "/Fm Do")
        }
        try assertGone(document)
    }

    func test_formReachedAgainThroughAFontNamedWithAStrayOperandIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("").replacingOccurrences(of: "/Font <</F1 5 0 R>>", with: "/Font <</F1 5 0 R /T3 8 0 R>>"), self.shows + " BT /Junk /T3 12 Tf 300 300 Td (b) Tj ET")
            pdf.obj(8, self.type3)
            pdf.stream(9, "", "1000 0 d0 /Fm Do")
        }
        try assertGone(document)
    }
}
