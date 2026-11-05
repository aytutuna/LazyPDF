import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/LinkTests.cs: the same cases. PdfPigSeesTheAddedLink has no twin (PdfPig).

final class LinkTests: XCTestCase {
    private func sample() throws -> PdfDocument {
        try StructureFixtures.file("", { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Link /Rect [10 20 110 40] /Dest [4 0 R /Fit]>>")
            pdf.obj(21, "<</Type /Annot /Subtype /Link /Rect [150 40 50 20] /A <</S /URI /URI (https://example.com)>>>>")
            pdf.obj(22, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5] /A <</S /GoTo /D [5 0 R /FitH 9]>>>>")
            pdf.obj(23, "<</Type /Annot /Subtype /Text /Rect [0 0 5 5] /Contents (note)>>")
            pdf.obj(24, "<</Type /Annot /Subtype /Link>>")
            pdf.obj(25, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5] /A <</S /Launch /F (x.exe)>>>>")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 99 0 R 7]")
    }

    func test_readsLinksOnly() throws {
        let document = try sample()
        let links = PdfLinks.read(document, document.pages[0])
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(links[0].rect, PdfRect(10, 20, 110, 40))
        XCTAssertEqual(links[0].destination?.pageIndex, 1)
        XCTAssertNil(links[0].action)
        XCTAssertEqual(links[1].uri, "https://example.com")
        XCTAssertEqual(links[1].rect, PdfRect(50, 20, 150, 40))
        XCTAssertNil(links[1].destination)
        XCTAssertEqual(links[2].destination?.pageIndex, 2)
        XCTAssertTrue(links[2].action is GoToAction)
        XCTAssertTrue(links[3].action is LaunchAction)
        XCTAssertEqual(links[0].reference?.number, 20)
    }

    func test_pageWithoutAnnotationsHasNoLinks() throws {
        let document = try sample()
        document.pages[1].dictionary.remove("Annots")
        XCTAssertTrue(PdfLinks.read(document, document.pages[1]).isEmpty)
    }

    func test_addsDestinationAndUriLinks() throws {
        let document = try StructureFixtures.open()
        let page = document.pages[0]
        let toPage = try PdfLinks.add(document, page, PdfRect(10, 10, 60, 30), PdfDestination(2, .fitH, top: 5))
        let toWeb = try PdfLinks.addUri(document, page, PdfRect(70, 10, 120, 30), "https://example.com/\u{E9}")
        let other = try PdfLinks.add(document, document.pages[1], PdfRect(1, 1, 2, 2), NamedAction("NextPage"))

        let reopened = try StructureFixtures.reopen(document)
        let links = PdfLinks.read(reopened, reopened.pages[0])
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].destination?.pageIndex, 2)
        XCTAssertEqual(links[1].uri, "https://example.com/\u{E9}")
        XCTAssertEqual(links[1].rect, PdfRect(70, 10, 120, 30))
        let onSecond = PdfLinks.read(reopened, reopened.pages[1])
        XCTAssertEqual(onSecond.count, 1)
        XCTAssertTrue(onSecond[0].action is NamedAction)
        XCTAssertNotEqual(toPage.number, toWeb.number)
        XCTAssertNotEqual(toWeb.number, other.number)
    }

    func test_addsToAnIndirectAnnotsArray() throws {
        let document = try StructureFixtures.file("", { pdf in pdf.obj(30, "[]") }, pageEntries: "/Annots 30 0 R")
        try PdfLinks.addUri(document, document.pages[0], PdfRect(1, 1, 5, 5), "http://x")
        XCTAssertEqual((document.get(30) as? PdfArray)?.items.count, 1)
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(PdfLinks.read(reopened, reopened.pages[0]).count, 1)
    }

    func test_removesALink() throws {
        let document = try sample()
        let page = document.pages[0]
        let links = PdfLinks.read(document, page)
        let reference = try XCTUnwrap(links[1].reference)
        XCTAssertTrue(PdfLinks.remove(document, page, reference))
        XCTAssertNil(document.get(21))
        XCTAssertFalse(PdfLinks.remove(document, page, reference))
        XCTAssertEqual(PdfLinks.read(document, page).count, 3)
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(PdfLinks.read(reopened, reopened.pages[0]).count, 3)
    }

    func test_removeOnPageWithoutAnnotsIsFalse() throws {
        let document = try StructureFixtures.open()
        XCTAssertFalse(PdfLinks.remove(document, document.pages[0], PdfReference(9, 0)))
    }

    func test_linkToAPageThatIsGoneCannotBeAdded() throws {
        let document = try StructureFixtures.open()
        XCTAssertThrowsError(try PdfLinks.add(document, document.pages[0], PdfRect(0, 0, 1, 1), PdfDestination(10))) { XCTAssertTrue($0 is ArgumentException) }
    }
}
