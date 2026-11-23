import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The per page scales of the Measure model: what the fields show for the page in view, what a typed value is stored under, and
// what a rewrite of the file, an undo or another tab does to them. Mirrors windows/LazyPDF.App.Tests/Tools/measure/MeasurePanelStateTests.cs.

@MainActor
final class MeasureScalesModelTests: XCTestCase {
    private let half = MeasureScale(1, .millimetre, 50, .millimetre)
    private let one = MeasureScale(1, .millimetre, 100, .millimetre)
    private let date = DateTimeOffset(2026, 1, 5, 9, 0, 0)

    private func attached(_ bytes: [UInt8]) throws -> (model: MeasureModel, rig: ToolRig) {
        let rig = try ToolRig(bytes)
        let model = MeasureModel(fonts: FakeFonts())
        model.author = "Sam"
        rig.attach(model)
        return (model, rig)
    }

    private func mark(_ tab: DocumentTab, _ page: Int, _ scale: MeasureScale) throws {
        let line = MeasureItem(.distance, page, [ViewPoint(100, 100), ViewPoint(172, 100)])
        _ = try MeasureWriter.write(tab.document, [line], { _ in scale }, author: "Sam", date: date)
        XCTAssertTrue(try tab.commit("Measure"))
    }

    // Deleting the first page leaves a gap that a compact closes, so the pages come out under other numbers.
    private func gapped(_ pages: Int) throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(pages + 1))
        try PageOperations.delete(session.document, [0])
        XCTAssertTrue(try session.commit("Delete"))
        return session.current
    }

    private func compact(_ tab: DocumentTab) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try tab.saveCompact(url)
    }

    private func numbers(_ tab: DocumentTab) -> [Int] {
        (0..<tab.document.pages.count).map { PageScales.key(tab.document, $0) }
    }

    private func waitingLine(_ tab: DocumentTab, _ page: Int) -> Pending {
        Pending(item: MeasureItem(.distance, page, [ViewPoint(0, 0), ViewPoint(10, 0)]), key: PageKey.of(tab.document.pages[page]))
    }

    func test_eachPageReadsItsOwnScaleAndTheFieldsFollowThePageInView() async throws {
        let (model, rig) = try attached(Pdfs.text(3))
        XCTAssertEqual(model.scaleHeading, "Scale for page 1")
        model.setRealValue("2")

        rig.viewer.pageIndex = 1
        await waitUntil { model.shownPage == 1 }

        XCTAssertEqual(model.realValue, "1")
        XCTAssertEqual(model.scaleHeading, "Scale for page 2")
        model.setRealValue("5")
        rig.viewer.pageIndex = 0
        await waitUntil { model.shownPage == 0 }
        XCTAssertEqual(model.realValue, "2")
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1).real, 5)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 2), .actual)
    }

    func test_theMeasurementsInTheListReadInTheScaleOfTheirPage() async throws {
        let (model, rig) = try attached(Pdfs.text(2))
        let tool = try XCTUnwrap(model.tool)
        for page in 0...1 {
            for x in [0.0, 72] {
                tool.press(PagePointer(page: page, point: ViewPoint(x, 0), view: ViewPoint(x, 0), pressed: true, clicks: 1))
            }
        }
        model.setRealUnit(.metre)

        XCTAssertEqual(model.rows.map(\.value), ["25.4 m", "25.4 mm"])
        XCTAssertEqual(rig.tab.pendingMeasurements, 2)
    }

    func test_anEditMadeWhileTheViewerAlreadyShowsTheNextPageLandsOnThePageTheFieldsShow() async throws {
        let (model, rig) = try attached(Pdfs.text(3))

        rig.viewer.pageIndex = 1
        model.setRealValue("7")

        XCTAssertEqual(model.scales.scale(rig.tab.document, 0).real, 7)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), .actual)
        await waitUntil { model.shownPage == 1 }
        XCTAssertEqual(model.realValue, "1")
    }

    func test_aTypedValueIsNotStoredForAGonePageOrWhileTheViewerShowsAnotherTab() async throws {
        let (model, rig) = try attached(Pdfs.text(3))
        rig.viewer.pageIndex = 2
        await waitUntil { model.shownPage == 2 }

        try PageOperations.delete(rig.tab.document, [2])
        model.setRealValue("7")
        rig.viewer.show(nil)
        model.setRealValue("8")
        rig.viewer.show(rig.tab)
        rig.viewer.pageIndex = 9
        model.setRealValue("9")

        XCTAssertTrue((0..<2).allSatisfy { model.scales.scale(rig.tab.document, $0) == .actual })
        XCTAssertFalse(model.canUseForAll)
    }

    func test_addToPageWritesEachMeasurementWithTheScaleOfItsPage() async throws {
        let (model, rig) = try attached(Pdfs.text(2))
        model.setRealValue("2")
        let tool = try XCTUnwrap(model.tool)
        for page in 0...1 {
            for x in [100.0, 172] {
                tool.press(PagePointer(page: page, point: ViewPoint(x, 100), view: ViewPoint(x, 100), pressed: true, clicks: 1))
            }
        }

        await model.action?.run()

        for (page, ratio, value) in [(0, "1 mm = 2 mm", "50.8 mm"), (1, "1 mm = 1 mm", "25.4 mm")] {
            let made = try XCTUnwrap(PdfAnnotations.read(rig.tab.document, rig.tab.document.pages[page]).first { $0.type == .line })
            let measure = try XCTUnwrap(rig.tab.document.resolve(made.dictionary["Measure"]) as? PdfDictionary)
            XCTAssertEqual(PdfText.read(rig.tab.document, measure, "R"), ratio)
            XCTAssertEqual(made.contents, "Distance: " + value)
        }
    }

    func test_aTypedScaleKeepsItsPageThroughASaveCompact() async throws {
        let (model, rig) = try attached(try gapped(5))
        let before = numbers(rig.tab)
        model.scales.set(before[2], one)

        try compact(rig.tab)
        await waitUntil { model.scales.scale(rig.tab.document, 2) == self.one }

        XCTAssertEqual(rig.tab.rewrites, 1)
        XCTAssertNotEqual(numbers(rig.tab), before)
        XCTAssertTrue([0, 1, 3, 4].allSatisfy { model.scales.scale(rig.tab.document, $0) == .actual })
    }

    func test_waitingLinesAndScalesFollowTheirPagesThroughCompactsDoneWhileDetached() async throws {
        let (model, rig) = try attached(try gapped(5))
        model.waiting.items.append(waitingLine(rig.tab, 4))
        model.scales.set(PageScales.key(rig.tab.document, 1), one)
        model.detach()

        try compact(rig.tab)
        try compact(rig.tab)
        rig.attach(model)

        XCTAssertEqual(rig.tab.rewrites, 2)
        XCTAssertEqual(model.waiting.items.count, 1)
        XCTAssertEqual(model.waiting.items[0].item.page, 4)
        XCTAssertEqual(model.waiting.items[0].key.number, PageScales.key(rig.tab.document, 4))
        XCTAssertTrue(rig.host.notices.isEmpty)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), one)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 2), .actual)
    }

    func test_aLineOnAPageDeletedWhileDetachedIsDroppedAfterACompact() async throws {
        let (model, rig) = try attached(Pdfs.text(6))
        model.waiting.items.append(waitingLine(rig.tab, 0))
        model.detach()

        try PageOperations.delete(rig.tab.document, [0])
        XCTAssertTrue(try rig.tab.commit("Delete"))
        try compact(rig.tab)
        rig.attach(model)

        XCTAssertTrue(model.waiting.items.isEmpty)
        XCTAssertEqual(rig.host.notices.map(\.title), ["Measurements dropped"])
    }

    func test_aScaleFoundOnAPageIsReadAgainWhenTheMarksAreGoneElsewhere() async throws {
        let rig = try ToolRig(Pdfs.text(2))
        try mark(rig.tab, 0, half)
        try mark(rig.tab, 1, one)
        let model = MeasureModel(fonts: FakeFonts())
        rig.attach(model)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), one)
        model.detach()

        rig.tab.document.pages[1].dictionary["Annots"] = nil
        XCTAssertTrue(try rig.tab.commit("Delete"))
        rig.attach(model)

        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), half)
    }

    func test_theFieldsFollowTheScaleWhenAnUndoTakesItsMarksAway() async throws {
        let rig = try ToolRig(Pdfs.text(3))
        try mark(rig.tab, 0, half)
        try mark(rig.tab, 2, one)
        rig.viewer.pageIndex = 2
        let model = MeasureModel(fonts: FakeFonts())
        rig.attach(model)
        XCTAssertEqual(model.realValue, "100")

        XCTAssertTrue(try rig.tab.undo())
        await waitUntil { model.realValue == "50" }

        XCTAssertEqual(model.scales.scale(rig.tab.document, 2), half)
    }

    func test_aCalibratedScaleShowsWithSixDigitsAndTheStoredOneKeepsAll() async throws {
        let (model, rig) = try attached(Pdfs.text(1))
        let calibrated = MeasureScale.from(points: 72, length: 1, pageUnit: .millimetre, realUnit: .metre)
        model.scales.set(PageScales.key(rig.tab.document, 0), calibrated)
        model.detach()
        rig.attach(model)

        XCTAssertEqual(model.realValue, "0.0393701")
        XCTAssertEqual(model.scales.scale(rig.tab.document, 0), calibrated)
    }

    func test_useForAllAsksBeforeReplacingAScaleOnAnotherPage() async throws {
        let (model, rig) = try attached(Pdfs.text(3))
        model.scales.set(PageScales.key(rig.tab.document, 1), half)
        model.setRealValue("100")

        model.useForAll()

        XCTAssertEqual(rig.host.notices.map(\.title), ["Replace the scales on the other pages?"])
        XCTAssertEqual(rig.host.notices[0].text, "The scale on 1 other page will be replaced.")
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), half)
        rig.host.notices[0].action?.run()
        XCTAssertTrue((0..<3).allSatisfy { model.scales.scale(rig.tab.document, $0) == self.one })
    }

    func test_useForAllWithNoScaleElsewhereJustApplies() async throws {
        let (model, rig) = try attached(Pdfs.text(3))
        model.setRealValue("100")

        model.useForAll()

        XCTAssertTrue(rig.host.notices.isEmpty)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 2), one)
    }

    func test_theConfirmationDoesNothingOnceAnotherTabIsShown() async throws {
        let (model, rig) = try attached(Pdfs.text(3))
        let other = try ToolRig(Pdfs.text(3))
        model.scales.set(PageScales.key(rig.tab.document, 1), half)
        model.setRealValue("100")
        model.useForAll()
        model.detach()
        other.attach(model)

        rig.host.notices[0].action?.run()

        XCTAssertEqual(model.scales.scale(other.tab.document, 1), .actual)
        XCTAssertEqual(model.pageValue, "1")
        model.detach()
        rig.attach(model)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 1), half)
    }
}
