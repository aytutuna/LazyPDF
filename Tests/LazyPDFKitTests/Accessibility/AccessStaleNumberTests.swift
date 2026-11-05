import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessStaleNumberTests.cs: the same cases. A [Theory] is one test that
// loops over its cases.

final class AccessStaleNumberTests: XCTestCase {
    private static func old(_ number: Int) -> String {
        "/P <</MCID \(number)>> BDC BT /F1 11 Tf 72 700 Td (Old) Tj ET EMC\n"
    }

    func test_aFarOffStaleNumberOnEveryPageDoesNotStopTheTagging() throws {
        let document = try PdfDocument.open(AccessKit.build(5) { _ in Self.old(999999) + AccessKit.text(72, 500, "New words") })

        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.pages, 5)
        let again = try AccessKit.reopen(document, rewrite: true)
        let tree = try XCTUnwrap(StructureTree.read(again))
        for content in tree.contents { XCTAssertLessThan(content.mcid, 100) }
    }

    func test_aStaleNumberAtTheLimitDoesNotPushTheNewOnesOutOfTheTree() throws {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in Self.old(1_000_000) + AccessKit.text(72, 500, "New words") })

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertTrue(ReadingOrder.export(again).contains("New words"))
    }

    func test_thePageThatOnlyDrawsArtifactsDoesNotKeepTheKeyOfATaggedPage() throws {
        let contents = [AccessKit.text(72, 700, "Words") + AccessKit.text(72, 600, "More words"), "/Figure <</MCID 0>> BDC 0 0 10 10 re f EMC\n"]
        let document = try PdfDocument.open(AccessKit.build(2, { i in contents[i] }, pageEntries: "/StructParents 0"))

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let tree = try XCTUnwrap(StructureTree.read(again))
        let first = again.integer(again.pages[0].dictionary, "StructParents")
        XCTAssertNotEqual(first, again.integer(again.pages[1].dictionary, "StructParents"))
        for content in tree.contents { XCTAssertEqual(content.pageIndex, 0) }
    }

    func test_theKeyOfAnUntaggedPageIsNotHandedToAnotherOwner() throws {
        let contents = [
            AccessKit.text(72, 700, "Words") + AccessKit.text(72, 600, "More words"), "0 0 10 10 re f\n",
            AccessKit.text(72, 700, "Third") + AccessKit.text(72, 600, "More"),
        ]
        let document = try PdfDocument.open(AccessKit.build(3, { i in contents[i] }, pageEntries: "/StructParents 1"))

        _ = try AutoTagger.tag(document)

        let keys = document.pages.compactMap { document.integer($0.dictionary, "StructParents") }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    private static func tagged(_ page: String, _ form: String) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>")
        pdf.stream(4, "", page)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K 8 0 R>>")
        pdf.obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", form)
        return pdf.finish()
    }

    func test_textOfAFormBelongsToTheSequenceAroundItsDrawingWhenTheFormNumbersThatNumberElsewhere() throws {
        let file = Self.tagged("/P <</MCID 2>> BDC /Fm1 Do EMC", "BT /F1 11 Tf 72 700 Td (Plain) Tj ET /Span <</MCID 2>> BDC BT /F1 11 Tf 72 650 Td (Marked) Tj ET EMC")
        let document = try PdfDocument.open(file)

        XCTAssertEqual(ReadingOrder.export(document), "Plain Marked")
    }

    func test_textOfAFormWithAStaleSequenceIsFoundUnderTheNewSequenceAroundTheDrawing() throws {
        for stale in [0, 7] {
            let form = "/P <</MCID \(stale)>> BDC BT /F1 11 Tf 72 700 Td (Form words) Tj ET EMC"
            let pdf = TestPdf()
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
            pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>")
            pdf.stream(4, "", "/Fm1 Do\n" + AccessKit.text(72, 500, "Page words"))
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", form)
            let document = try PdfDocument.open(pdf.finish())

            _ = try AutoTagger.tag(document)

            let again = try AccessKit.reopen(document, rewrite: true)
            let order = ReadingOrder.export(again)
            XCTAssertTrue(order.contains("Form words"), "stale \(stale)")
            XCTAssertTrue(order.contains("Page words"), "stale \(stale)")
        }
    }

    func test_aSequenceOfAnOuterFormIsNotMixedUpWithTheSameNumberOnThePage() throws {
        let document = try PdfDocument.open(Self.nestedFile())

        XCTAssertEqual(ReadingOrder.export(document), "Page text\nInner text")
    }

    private static func nestedFile() -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</FmA 10 0 R>>>>>>")
        pdf.stream(4, "", "/P <</MCID 2>> BDC BT /F1 11 Tf 72 700 Td (Page text) Tj ET EMC /FmA Do")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K [8 0 R 9 0 R]>>")
        pdf.obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>")
        pdf.obj(9, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K <</Type /MCR /Pg 3 0 R /MCID 2 /Stm 10 0 R>>>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</XObject <</FmB 11 0 R>>>>", "/Span <</MCID 2>> BDC /FmB Do EMC")
        pdf.stream(11, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 650 Td (Inner text) Tj ET")
        return pdf.finish()
    }

    private static func drawn(_ page: String, _ kids: String) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>")
        pdf.stream(4, "", page)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K [\(kids)]>>")
        pdf.obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 0>>")
        pdf.obj(9, "<</Type /StructElem /S /H1 /P 7 0 R /Pg 3 0 R /K 1>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 700 Td (Label) Tj ET")
        return pdf.finish()
    }

    func test_aFormDrawnInTwoSequencesGivesEachItsOwnText() throws {
        let document = try PdfDocument.open(Self.drawn(
            "/P <</MCID 0>> BDC /Fm1 Do EMC /H1 <</MCID 1>> BDC q 1 0 0 1 0 -100 cm /Fm1 Do Q EMC", "8 0 R 9 0 R"))

        XCTAssertEqual(ReadingOrder.export(document), "Label\n# Label")
    }

    func test_aDrawingOfAFormOutsideEverySequenceStaysOutOfTheOneBeforeIt() throws {
        let document = try PdfDocument.open(Self.drawn("/P <</MCID 0>> BDC /Fm1 Do EMC q 1 0 0 1 0 -100 cm /Fm1 Do Q", "8 0 R"))

        XCTAssertEqual(ReadingOrder.export(document), "Label")
    }

    func test_aStaleKeyOnAFormOutsideTheTreeIsNotLeftPointingAtAPage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>> /StructParents 0>>")
        pdf.stream(4, "", "/Fm1 Do\n" + AccessKit.text(72, 500, "Page words"))
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /StructParents 0 /Resources <</Font <</F1 5 0 R>>>>",
                   "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Form words) Tj ET EMC")
        let document = try PdfDocument.open(pdf.finish())

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let page = again.integer(again.pages[0].dictionary, "StructParents")
        let xobject = try XCTUnwrap(again.objectNumbers.compactMap { again.get($0) as? PdfStream }.first { again.name($0.dictionary, "Subtype") == "Form" })
        let form = again.integer(xobject.dictionary, "StructParents")
        XCTAssertNotNil(page)
        XCTAssertNotEqual(page, form)
    }
}
