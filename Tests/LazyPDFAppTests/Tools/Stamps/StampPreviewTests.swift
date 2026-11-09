import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/stamps/StampPreviewTests.cs: the pending stamp as drawn on the page: the words it shows
// and whether it shows at all. The Windows tests that read a TextBlock of a Canvas read the text mark of the overlay here.

final class StampPreviewTests: XCTestCase {
    private let page = ViewSize(595, 842)
    private let today = DateTimeOffset(2026, 11, 4, 9, 0, 0)

    private func expand(_ template: String) -> String {
        StampPreview.expand(template, page: 3, pages: 12, bates: "B-7", fileName: "a.pdf", date: today, dateFormat: "yyyy-MM-dd")
    }

    private func build(_ draft: StampDraft, page number: Int = 0, count: Int = 1, ordinal: Int = 0, fileName: String = "a.pdf") -> [OverlayItem] {
        StampPreview.build(draft, picture: nil, page: number, pageCount: count, ordinal: ordinal, size: page, fileName: fileName, now: today)
    }

    private func text(_ item: OverlayItem) throws -> OverlayText {
        guard case .text(let shown) = item.shape else {
            XCTFail("The mark should be a text.")
            throw CancellationError()
        }
        return shown
    }

    func test_tokensFillInAndUnknownOnesStayAsTyped() {
        XCTAssertEqual(expand("Page {page} of {pages}"), "Page 3 of 12")
        XCTAssertEqual(expand("{file} {bates}"), "a.pdf B-7")
        XCTAssertEqual(expand("{nope} and {"), "{nope} and {")
    }

    func test_aBatesTokenWithoutBatesNumbersStaysAsTyped() {
        XCTAssertEqual(StampPreview.expand("{bates}", page: 3, pages: 12, bates: nil, fileName: "a.pdf", date: today, dateFormat: "yyyy-MM-dd"), "{bates}")
    }

    func test_aDateTakesItsOwnFormatOrTheDefault() {
        XCTAssertEqual(expand("{date}"), "2026-11-04")
        XCTAssertEqual(expand("{date:dd/MM/yyyy}"), "04/11/2026")
        XCTAssertEqual(expand("{date:%%q}"), "{date:%%q}")
        XCTAssertEqual(StampPreview.expand("{date:}", page: 3, pages: 12, bates: nil, fileName: "a.pdf", date: today, dateFormat: "dd.MM.yyyy"), "04.11.2026")
    }

    func test_aWatermarkIsOneTextOnTheLayer() throws {
        let draft = StampDraft(watermark: WatermarkSpec(text: "DRAFT", rotation: 45))

        let items = build(draft)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try text(items[0]).text, "DRAFT")
        XCTAssertEqual(items[0].opacity, 0.3)
        XCTAssertEqual(items[0].rotation, -45)
        XCTAssertTrue(items[0].id.hasPrefix(StampPreview.prefix))
    }

    func test_aWatermarkTextIsSizedToTheShareOfThePageWidthItAsksFor() throws {
        let draft = StampDraft(watermark: WatermarkSpec(text: "DRAFT", scale: 0.6))

        let shown = try text(build(draft)[0])

        XCTAssertEqual(StampPreview.width("DRAFT", "Helvetica", .bold, shown.look.size), 0.6 * page.width, accuracy: 1)
    }

    func test_aBatesNumberCountsFromTheStartByThePagesStamped() throws {
        let spec = HeaderFooterSpec(footer: HeaderFooterBand("", "", "{bates}"), bates: BatesSpec(prefix: "ACME-", suffix: "", digits: 4, start: 10))

        let items = build(StampDraft(headerFooter: spec), page: 5, count: 8, ordinal: 2)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try text(items[0]).text, "ACME-0012")
    }

    func test_aSlotThatExpandsToNothingDrawsNothing() {
        let spec = HeaderFooterSpec(header: HeaderFooterBand("{file}"))

        XCTAssertTrue(build(StampDraft(headerFooter: spec), fileName: "").isEmpty)
    }

    func test_aBatesTokenInAPlainHeaderIsDrawnAsTyped() throws {
        let spec = HeaderFooterSpec(header: HeaderFooterBand("{bates}"))

        let items = build(StampDraft(headerFooter: spec))

        XCTAssertEqual(try text(items[0]).text, "{bates}")
    }

    func test_theFooterSitsAboveTheBottomMargin() throws {
        let spec = HeaderFooterSpec(footer: HeaderFooterBand("", "{page}", ""))

        let shown = try text(build(StampDraft(headerFooter: spec))[0])

        XCTAssertLessThan(shown.at.y, page.height - spec.marginBottom)
        XCTAssertGreaterThan(shown.at.y, page.height - spec.marginBottom - 20)
    }

    func test_aBackgroundPictureIsPlacedWhereTheEngineCentresIt() {
        let wide = (width: 200.0, height: 100.0)
        let square = ViewSize(100, 100)

        XCTAssertEqual(StampPreview.fitted(.cover, wide.width, wide.height, square), ViewRect(-50, 0, 200, 100))
        XCTAssertEqual(StampPreview.fitted(.contain, wide.width, wide.height, square), ViewRect(0, 25, 100, 50))
        XCTAssertEqual(StampPreview.fitted(.stretch, wide.width, wide.height, square), ViewRect(0, 0, 100, 100))
    }

    func test_aBackgroundWithoutAColourOrPictureDrawsNothing() {
        XCTAssertTrue(build(StampDraft(background: BackgroundSpec())).isEmpty)
    }

    func test_aBackgroundStaysFaintInFrontOfThePage() {
        let items = build(StampDraft(background: BackgroundSpec(color: .gray(0.9), opacity: 1)))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].opacity, 0.25)
    }
}
