import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessDrawingOwnerTests.cs: the same cases. A [Theory] is one test that
// loops over its cases.

final class AccessDrawingOwnerTests: XCTestCase {
    private static func drawn(_ page: String) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>")
        pdf.stream(4, "", page)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K [8 0 R 9 0 R]>>")
        pdf.obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 0>>")
        pdf.obj(9, "<</Type /StructElem /S /H1 /P 7 0 R /Pg 3 0 R /K 1>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 700 Td (Label) Tj ET")
        return pdf.finish()
    }

    func test_aDropShadowDoesNotTakeTheTextOfTheDrawingItCopies() throws {
        for page in [
            "/Artifact BMC q 1 0 0 1 1 -2 cm /Fm1 Do Q EMC /P <</MCID 0>> BDC /Fm1 Do EMC",
            "/P <</MCID 0>> BDC /Fm1 Do EMC /Artifact BMC q 1 0 0 1 1 -2 cm /Fm1 Do Q EMC",
        ] {
            let document = try PdfDocument.open(Self.drawn(page))

            XCTAssertEqual(ReadingOrder.export(document), "Label", page)
        }
    }

    func test_twoSequencesDrawingTheFormCloseTogetherEachKeepTheirOwnCopy() throws {
        let document = try PdfDocument.open(Self.drawn("/P <</MCID 0>> BDC /Fm1 Do EMC /H1 <</MCID 1>> BDC q 1 0 0 1 0 -3 cm /Fm1 Do Q EMC"))

        XCTAssertEqual(ReadingOrder.export(document), "Label\n# Label")
    }

    func test_aDrawingThePageDoesNotShowIsNotTheOwnerOfTheVisibleOne() throws {
        for page in [
            "q 0 0 1 1 re W n /Fm1 Do Q /P <</MCID 0>> BDC /Fm1 Do EMC",
            "q 7 Tr /Fm1 Do Q /P <</MCID 0>> BDC /Fm1 Do EMC",
        ] {
            let document = try PdfDocument.open(Self.drawn(page))

            XCTAssertEqual(ReadingOrder.export(document), "Label", page)
        }
    }

    func test_aSequenceWhoseDrawingIsClippedAwayGetsNothingFromTheVisibleOne() throws {
        let document = try PdfDocument.open(Self.drawn("/H1 <</MCID 1>> BDC q 0 0 1 1 re W n /Fm1 Do Q EMC /P <</MCID 0>> BDC /Fm1 Do EMC"))

        XCTAssertEqual(ReadingOrder.export(document), "Label")
    }

    private static func twoPages(_ extra: String) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>> /StructParents 0>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.stream(5, "", AccessKit.text(72, 700, "First page words") + AccessKit.text(72, 600, "More words"))
        pdf.stream(6, "", AccessKit.text(72, 700, "Second page words") + AccessKit.text(72, 600, "More words"))
        pdf.obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(8, extra)
        return pdf.finish()
    }

    func test_anUnreferencedObjectWithTheLargestKeyDoesNotMakeNewKeysCollide() throws {
        let document = try PdfDocument.open(Self.twoPages("<</StructParents 9223372036854775807>>"))

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let first = again.integer(again.pages[0].dictionary, "StructParents")
        let second = again.integer(again.pages[1].dictionary, "StructParents")
        XCTAssertEqual(first, 0)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func test_aStaleKeyOnADirectAnnotationIsNotHandedToThePage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /Annots [<</Subtype /Text /Rect [0 0 10 10] /StructParent 0>>]>>")
        pdf.stream(4, "", AccessKit.text(72, 700, "Page words") + AccessKit.text(72, 600, "More words"))
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        let document = try PdfDocument.open(pdf.finish())

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let first = try XCTUnwrap(try XCTUnwrap(again.array(again.pages[0].dictionary, "Annots")).items.first)
        let annotation = try XCTUnwrap(again.resolve(first) as? PdfDictionary)
        let page = again.integer(again.pages[0].dictionary, "StructParents")
        XCTAssertNotNil(page)
        XCTAssertNotEqual(page, again.integer(annotation, "StructParent"))
    }

    func test_aStaleKeyOnAnIndirectAnnotationTheTaggerSkipsIsNotHandedToThePage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /Annots [6 0 R]>>")
        pdf.stream(4, "", AccessKit.text(72, 700, "Page words") + AccessKit.text(72, 600, "More words"))
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /Annot /Subtype /Popup /Rect [0 0 10 10] /StructParent 0>>")
        let document = try PdfDocument.open(pdf.finish())

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let first = try XCTUnwrap(try XCTUnwrap(again.array(again.pages[0].dictionary, "Annots")).items.first)
        let annotation = try XCTUnwrap(again.resolve(first) as? PdfDictionary)
        let page = again.integer(again.pages[0].dictionary, "StructParents")
        XCTAssertNotNil(page)
        XCTAssertNotEqual(page, again.integer(annotation, "StructParent"))
    }
}
