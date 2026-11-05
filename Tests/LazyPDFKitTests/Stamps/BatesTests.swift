import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/BatesTests.cs: the same cases. The PdfPig line of ABatesRunIsListedAsOneAndSurvivesSaving
// has no twin.

final class BatesTests: XCTestCase {
    private func footer(_ bates: BatesSpec, _ pages: [Int]? = nil) -> HeaderFooterSpec {
        HeaderFooterSpec(footer: HeaderFooterBand("", "", "{bates}"), bates: bates, pages: pages)
    }

    private func shown(_ document: PdfDocument, _ page: Int) -> String { StampKit.text(StampKit.glyphs(document, page)) }

    func test_numbersHavePrefixSuffixAndDigits() {
        let bates = BatesSpec(prefix: "ACME-", suffix: "/A", digits: 5, start: 41)
        XCTAssertEqual(bates.format(41), "ACME-00041/A")
        XCTAssertEqual(bates.format(123456), "ACME-123456/A")
        XCTAssertEqual(BatesSpec(digits: 0).format(7), "7")
    }

    func test_aBatchContinuesFromTheNextNumberReturned() throws {
        let first = try StampKit.doc(3)
        let second = try StampKit.doc(2)
        let one = try PdfStamper(first).addHeaderFooter(footer(BatesSpec(prefix: "DOC", digits: 4, start: 1)))
        XCTAssertEqual(one.nextBates, 4)
        let two = try PdfStamper(second).addHeaderFooter(footer(BatesSpec(prefix: "DOC", digits: 4, start: one.nextBates)))
        XCTAssertEqual(two.nextBates, 6)

        XCTAssertEqual(shown(first, 0), "DOC0001")
        XCTAssertEqual(shown(first, 2), "DOC0003")
        XCTAssertEqual(shown(second, 0), "DOC0004")
        XCTAssertEqual(shown(second, 1), "DOC0005")
    }

    func test_onlyStampedPagesUseUpNumbers() throws {
        let document = try StampKit.doc(4)
        let run = try PdfStamper(document).addHeaderFooter(footer(BatesSpec(start: 10), [3, 1]))
        XCTAssertEqual(run.nextBates, 12)
        XCTAssertEqual(shown(document, 1), "000010")
        XCTAssertEqual(shown(document, 3), "000011")
    }

    func test_aBatesRunIsListedAsOneAndSurvivesSaving() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addHeaderFooter(footer(BatesSpec(prefix: "X-", digits: 3, start: 1)))
        let file = try StampKit.rewrite(document)
        let reopened = try PdfDocument.open(file)
        XCTAssertEqual(try StampKit.single(PdfStamper(reopened).list()).kind, .bates)
    }

    func test_withoutASpecTheTokenIsLeftAndNoNumberIsReturned() throws {
        let document = try StampKit.doc(1)
        let run = try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "", "{bates}")))
        XCTAssertEqual(run.nextBates, 0)
        XCTAssertEqual(shown(document, 0), "{bates}")
    }
}
