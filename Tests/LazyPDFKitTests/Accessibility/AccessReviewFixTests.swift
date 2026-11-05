import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessReviewFixTests.cs: the same cases.

final class AccessReviewFixTests: XCTestCase {
    // A page that draws its text in a sequence of its own and a form that numbers a sequence 2 as well.
    private static func pageWithForm() -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /StructParents 0 /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>")
        pdf.stream(4, "", "/P <</MCID 2>> BDC BT /F1 11 Tf 72 700 Td (Page text) Tj ET EMC /Fm1 Do\n")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1>>")
        pdf.obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K 8 0 R>>")
        pdf.obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>")
        pdf.obj(9, "<</Nums [0 [null null 8 0 R]]>>")
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "/Span <</MCID 2>> BDC BT /F1 11 Tf 72 650 Td (Form text) Tj ET EMC")
        return pdf.finish()
    }

    func test_aSequenceOfAFormIsNotTakenForTheSequenceOfThePageWithTheSameNumber() throws {
        let document = try PdfDocument.open(Self.pageWithForm())

        XCTAssertEqual(ReadingOrder.export(document), "Page text")
    }

    func test_aFormSequenceMissingFromTheTreeIsLooseEvenWhenThePageHoldsThatNumber() throws {
        let document = try PdfDocument.open(Self.pageWithForm())

        XCTAssertEqual(try AccessibilityChecker.check(document)[.taggedContent].status, .failed)
    }

    func test_contentWithStaleSequencesIsTaggedAndNumbersAreNotRepeated() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Old words) Tj ET EMC\n" + AccessKit.text(72, 500, "New words")
        let document = try PdfDocument.open(AccessKit.build(1) { _ in content })

        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.pages, 1)
        let again = try AccessKit.reopen(document, rewrite: true)
        let order = ReadingOrder.export(again)
        XCTAssertTrue(order.contains("Old words"))
        XCTAssertTrue(order.contains("New words"))
        let numbers = AccessKit.sequences(again, 0).filter { $0.mcid >= 0 }.map { $0.mcid }
        XCTAssertEqual(numbers.count, Set(numbers).count)
    }

    func test_pagesThatCarryTheSameStaleKeyGetOwnParentTreeEntries() throws {
        let document = try PdfDocument.open(AccessKit.build(2, { i in
            AccessKit.text(72, 700, "Page \(i + 1) words") + AccessKit.text(72, 600, "More words")
        }, pageEntries: "/StructParents 0"))

        _ = try AutoTagger.tag(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let tree = try XCTUnwrap(StructureTree.read(again))
        let keys = try again.pages.map { try XCTUnwrap(again.integer($0.dictionary, "StructParents")) }
        XCTAssertEqual(Set(keys).count, 2)
        for p in 0..<2 {
            for sequence in AccessKit.sequences(again, p) where sequence.mcid >= 0 {
                let kids = try XCTUnwrap(tree.elementFor(keys[p], sequence.mcid)).kids
                XCTAssertTrue(kids.contains { kid in
                    guard let content = kid as? StructContent else { return false }
                    return content.pageIndex == p && content.mcid == sequence.mcid
                })
            }
        }
    }

    func test_annotationWithAStaleKeyDoesNotTakeThePageEntry() throws {
        let document = try TaggedFile.open { objects in
            objects[14] = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /StructParent 0 /P 3 0 R>>"
            objects[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 15 0 R]>>"
            objects[15] = "<</Type /StructElem /S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 14 0 R /Pg 3 0 R>>>>"
        }
        let tree = try XCTUnwrap(StructureTree.read(document))
        try tree.write(document)

        let rebuilt = try XCTUnwrap(StructureTree.read(document))
        let page = try XCTUnwrap(document.integer(document.pages[0].dictionary, "StructParents"))
        let annotation = try XCTUnwrap(document.integer(try XCTUnwrap(document.resolve(PdfReference(14, 0)) as? PdfDictionary), "StructParent"))
        XCTAssertNotEqual(page, annotation)
        XCTAssertEqual(rebuilt.elementFor(page, 1)?.type, "P")
    }

    func test_theStreamOwnerOfAnMcrSurvivesWrite() throws {
        let file = TaggedFile.build { objects in
            objects[11] = "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K <</Type /MCR /Pg 3 0 R /MCID 0 /Stm 14 0 R /StmOwn 3 0 R>>>>"
            objects[14] = "<</Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0>>\nstream\n\nendstream"
        }
        let withForm = try PdfDocument.open(file)
        let tree = try XCTUnwrap(StructureTree.read(withForm))

        try tree.write(withForm)

        let mcr = try XCTUnwrap(withForm.dict(try XCTUnwrap(withForm.resolve(PdfReference(11, 0)) as? PdfDictionary), "K"))
        XCTAssertEqual(mcr["StmOwn"]?.description, "3 0 R")
    }

    func test_aTreeThatNamesFarOffSequencesOnManyPagesIsRefusedBeforeAnythingIsAllocated() throws {
        let pages = 6
        let bytes = AccessKit.build(pages, { _ in AccessKit.text(72, 700, "Words") }, catalog: "/StructTreeRoot 40 0 R", pageEntries: "", more: { pdf in
            pdf.obj(40, "<</Type /StructTreeRoot /K 41 0 R>>")
            pdf.obj(41, "<</Type /StructElem /S /Document /P 40 0 R /K [" + (0..<pages).map { "\(42 + $0) 0 R" }.joined(separator: " ") + "]>>")
            for i in 0..<pages { pdf.obj(42 + i, "<</Type /StructElem /S /P /P 41 0 R /Pg \(3 + i) 0 R /K 1000000>>") }
        })
        let document = try PdfDocument.open(bytes)
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertFalse(tree.isTruncated)
        XCTAssertThrowsError(try tree.write(document)) { XCTAssertTrue($0 is InvalidOperationException) }
    }
}
