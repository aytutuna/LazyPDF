import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/UnbalancedPageTests.cs: the same cases. The stamp must land where it was asked to
// whatever state the page leaves behind. Positions are compared to 1e-9, where the C# compares the doubles themselves.

final class UnbalancedPageTests: XCTestCase {
    private let page = "BT /F1 12 Tf 50 50 Td (p) Tj ET"

    private func stamped(_ content: String, _ stamp: (PdfStamper) throws -> StampRun) throws -> StampGlyph {
        let document = try StampKit.pages([(keys: "", content: content)])
        _ = try stamp(PdfStamper(document))
        return try StampKit.single(StampKit.glyphs(document, 0).filter { $0.text == "S" })
    }

    private func header(_ s: PdfStamper) throws -> StampRun {
        try s.addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("S", "", "")))
    }

    private func mark(_ s: PdfStamper) throws -> StampRun {
        try s.addWatermark(WatermarkSpec(text: "S", rotation: 20))
    }

    private var pages: [String] {
        [
            "q 2 0 0 2 10 10 cm 0 1 0 rg " + page,
            "q q q 0.5 0 0 0.5 0 0 cm " + page,
            "5 0 0 5 0 0 cm " + page,
            page + " Q Q Q",
            "BT /F1 12 Tf 50 50 Td (p) Tj",
            "/Span BMC q 3 0 0 3 0 0 cm " + page,
            "1 0 0 RG 20 w [3] 0 d 0.3 g 0 0 1 rg 4 Tr 9 Tc",
        ]
    }

    func test_aHeaderLandsWhereItLandsOnACleanPage() throws {
        let clean = try stamped(page, header)
        for content in pages {
            let odd = try stamped(content, header)
            XCTAssertEqual(odd.x, clean.x, accuracy: 1e-9, content)
            XCTAssertEqual(odd.y, clean.y, accuracy: 1e-9, content)
            XCTAssertEqual(odd.size, clean.size, accuracy: 1e-9, content)
        }
    }

    func test_aWatermarkLandsWhereItLandsOnACleanPage() throws {
        let clean = try stamped(page, mark)
        for content in pages {
            let odd = try stamped(content, mark)
            XCTAssertEqual(odd.x, clean.x, accuracy: 1e-9, content)
            XCTAssertEqual(odd.y, clean.y, accuracy: 1e-9, content)
            XCTAssertEqual(odd.size, clean.size, accuracy: 1e-9, content)
            XCTAssertEqual(odd.dirX, clean.dirX, accuracy: 1e-9, content)
        }
    }

    func test_aBehindStampNeedsNoHelpFromThePage() throws {
        let document = try StampKit.pages([(keys: "", content: "q q 4 0 0 4 0 0 cm " + page)])
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "S", rotation: 0, behind: true))
        let clean = try StampKit.doc(1)
        try PdfStamper(clean).addWatermark(WatermarkSpec(text: "S", rotation: 0, behind: true))
        XCTAssertEqual(StampKit.glyphs(document, 0)[0].x, StampKit.glyphs(clean, 0)[0].x, accuracy: 5e-7)
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 2)
    }

    func test_theWrapperClosesAsManyAsThePageLeavesOpen() throws {
        let document = try StampKit.pages([(keys: "", content: "q q q BT /Span BMC")])
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "S"))
        let streams = try StampKit.contentStreams(document, 0)
        let items = try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"]) as? PdfArray).items
        let close = try XCTUnwrap(document.resolve(items[items.count - 2]) as? PdfStream)
        let text = Latin1.string(try XCTUnwrap(close.data))
        XCTAssertEqual(text, "ET\nEMC\nQ\nQ\nQ\nQ\n")
        XCTAssertEqual(streams.count, 4)
    }

    func test_aRunawayPageCannotBloatTheWrapper() throws {
        let document = try StampKit.pages([(keys: "", content: String(repeating: "q ", count: 50000) + String(repeating: "Q ", count: 70000))])
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "S"))
        let items = try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"]) as? PdfArray).items
        for item in [items[0], items[items.count - 2]] {
            XCTAssertTrue(try XCTUnwrap(try XCTUnwrap(document.resolve(item) as? PdfStream).data).count <= 2000 * 2)
        }
    }
}
