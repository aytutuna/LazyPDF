import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactReachTests.cs: the same cases. What the interpreter does not enter is not
// looked at, and a copy of the form would still name it: loops that depend on where a name is looked up, loops through other
// kinds of content, marked content nested over several streams. Each makes the page a picture.

final class RedactReachTests: XCTestCase {
    private let near = PdfRect(90, 90, 200, 120)
    private let away = "[300 300 400 400]"
    private let shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET"

    private func form(_ resources: String, _ box: String = "[0 0 600 800]") -> String {
        "/Type /XObject /Subtype /Form /BBox \(box) /Resources <</Font <</F1 5 0 R>> \(resources)>>"
    }

    private func flat(_ document: PdfDocument) throws {
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }

    func test_formEnteredAgainUnderAnotherScopeIsCut() throws {
        let document = try RedactionKit.page("/Fm Do /G Do", "/XObject <</Fm 6 0 R /G 7 0 R /N 8 0 R>>") { pdf in
            pdf.stream(6, self.form(""), self.shows + " q 1 0 0 1 5000 0 cm /N Do Q")
            pdf.stream(7, self.form("/XObject <</Fm 6 0 R /N 6 0 R>>"), "/Fm Do")
            pdf.stream(8, self.form(""), "")
        }
        try flat(document)
    }

    func test_loopThatOnlyOnePathThroughASharedFormClosesIsFound() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/XObject <</A 7 0 R /B 8 0 R>>"), self.shows + " /A Do /B Do")
            pdf.stream(7, self.form("/XObject <</X 9 0 R /N 10 0 R>>", self.away), "/X Do")
            pdf.stream(8, self.form("/XObject <</X 9 0 R /N 6 0 R>>", self.away), "/X Do")
            pdf.stream(9, self.form("", self.away), "/N Do")
            pdf.stream(10, self.form("", self.away), "")
        }
        try flat(document)
    }

    func test_formReachedAgainThroughATilingPatternIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/Pattern <</P1 7 0 R>>"), self.shows + " /Pattern cs /P1 scn 300 300 5 5 re f")
            pdf.stream(7, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do")
        }
        try flat(document)
    }

    func test_formReachedAgainThroughASoftMaskGroupIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/ExtGState <</G 7 0 R>>"), self.shows + " /G gs 300 300 5 5 re f")
            pdf.obj(7, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>")
            pdf.stream(8, self.form("/XObject <</Fm 6 0 R>>") + " /Group <</S /Transparency>>", "/Fm Do")
        }
        try flat(document)
    }

    func test_formReachedAgainThroughAType3ProcedureIsCut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("").replacingOccurrences(of: "/Font <</F1 5 0 R>>", with: "/Font <</F1 5 0 R /T3 7 0 R>>"), self.shows + " BT /T3 12 Tf 300 300 Td (b) Tj ET")
            pdf.obj(7, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</b 8 0 R>> "
                + "/Encoding <</Type /Encoding /Differences [98 /b]>> /FirstChar 98 /LastChar 98 /Widths [1000] /Resources <</XObject <</Fm 6 0 R>>>>>>")
            pdf.stream(8, "", "1000 0 d0 /Fm Do")
        }
        try flat(document)
    }

    func test_cyclicFormWhoseBoxMissesTheMarkIsCutWhereTheTextIs() throws {
        for box in ["[250 250 400 400]", "[0 0 0 0]"] {
            let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
                pdf.stream(6, self.form("/XObject <</Fm 6 0 R>>", box), self.shows + " q 1 0 0 1 5000 0 cm /Fm Do Q")
            }
            try flat(document)
        }
    }

    func test_markedContentOpenedAcrossTheStreamsPastTheLimitIsNotFollowed() throws {
        let outer = String(repeating: "/X BMC ", count: 1000)
        let inner = String(repeating: "/X BMC ", count: 40)
        let document = try RedactionKit.page(outer + "/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form(""), inner + "/Span <</Alt (ZQXDESCR)>> BDC BT /F1 12 Tf 100 100 Td (xyzw) Tj ET EMC")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXDESCR")
    }

    func test_inlineImageWhoseEndTheParserMayHaveMissedMakesThePagePicture() throws {
        let document = try RedactionKit.page("q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID 00> EI Q BT (M\u{FC}ller) Tj /F1 12 Tf 100 100 Td (ZQXAFTER) Tj ET")
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXAFTER")
    }

    func test_filteredInlineImageMakesThePagePicture() throws {
        let document = try RedactionKit.page("q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID 00> EI Q BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET")
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }
}
