import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/measure/MeasureMathTests.cs and MeasurePendingTests.cs: what the numbers of the
// measure tool come to, before any page or pointer is involved, and measurements waiting in the panel against the file
// changing under them.

@MainActor
final class MeasureMathTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> ViewPoint { ViewPoint(x, y) }

    func test_aScaleTurnsPointsIntoTheRealUnit() async {
        let scale = MeasureScale(1, .inch, 10, .foot)

        XCTAssertEqual(scale.perPoint, 10.0 / 72, accuracy: 1e-9)
        XCTAssertEqual(scale.length(72), "10 ft")
        XCTAssertEqual(scale.area(72 * 72), "100 ft²")
        XCTAssertEqual(scale.ratio, "1 in = 10 ft")
    }

    func test_millimetresOnThePageAreMillimetresInTheWorldByDefault() async {
        XCTAssertEqual(MeasureScale.actual.length(25 / 25.4 * 72), "25 mm")
    }

    func test_aRatioReadsBackAsTheScaleThatWroteIt() async {
        for scale in [MeasureScale(1, .inch, 10, .foot), MeasureScale(2.5, .centimetre, 1000, .kilometre), MeasureScale(1, .millimetre, 50, .metre),
                      MeasureScale(0.25, .inch, 1, .mile), MeasureScale(1, .centimetre, 3, .yard)] {
            XCTAssertEqual(MeasureScale.tryParse(scale.ratio), scale)
        }
    }

    func test_textThatIsNoRatioReadsAsNothing() async {
        for text in ["x", "1 mm", "0 mm = 1 m", "1 mm = 2 parsec", "1mm = 2 m", "1 mm = 2 m = 3 m"] {
            XCTAssertNil(MeasureScale.tryParse(text), text)
        }
    }

    func test_aScaleNeedsPositiveNumbers() async {
        for (page, real) in [(0.0, 1.0), (1, 0), (-2, 1), (Double.nan, 1)] {
            XCTAssertFalse(MeasureScale(page, .inch, real, .metre).isValid, "\(page) \(real)")
        }
        XCTAssertTrue(MeasureScale(1, .inch, 1, .metre).isValid)
    }

    func test_aLengthIsTheSumOfItsSegmentsAndAPerimeterCloses() async {
        let corners = [p(0, 0), p(30, 0), p(30, 40)]

        XCTAssertEqual(MeasureShape.length(corners, closed: false), 70, accuracy: 1e-9)
        XCTAssertEqual(MeasureShape.length(corners, closed: true), 120, accuracy: 1e-9)
    }

    func test_anAreaIsTheSameWhicheverWayRound() async {
        let square = [p(0, 0), p(10, 0), p(10, 10), p(0, 10)]

        XCTAssertEqual(MeasureShape.area(square), 100, accuracy: 1e-9)
        XCTAssertEqual(MeasureShape.area(square.reversed()), 100, accuracy: 1e-9)
        XCTAssertEqual(MeasureShape.area([p(0, 0), p(5, 5)]), 0, accuracy: 1e-9)
    }

    func test_shiftKeepsToMultiplesOfFortyFiveDegrees() async {
        let flat = MeasureShape.straighten(p(0, 0), p(10, 1))
        let slanted = MeasureShape.straighten(p(5, 5), p(15, 16))

        XCTAssertEqual(flat.y, 0, accuracy: 1e-9)
        XCTAssertEqual(flat.x, 101.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(slanted.x - 5, slanted.y - 5, accuracy: 1e-9)
    }

    func test_snappingTakesTheNearestPointWithinReach() async {
        let corners = [p(10, 10), p(12, 10), p(50, 50)]

        XCTAssertEqual(MeasureShape.nearest(corners, p(13, 10), 3), p(12, 10))
        XCTAssertNil(MeasureShape.nearest(corners, p(30, 30), 3))
    }

    func test_aMeasurementReadsInTheScaleAndSitsAtItsMiddle() async {
        let scale = MeasureScale(1, .inch, 1, .metre)
        let line = MeasureItem(.distance, 0, [p(0, 0), p(144, 0)])
        let area = MeasureItem(.area, 0, [p(0, 0), p(72, 0), p(72, 72), p(0, 72)])
        var outline = area
        outline.kind = .perimeter

        XCTAssertEqual(line.value(scale), "2 m")
        XCTAssertEqual(area.value(scale), "1 m²")
        XCTAssertEqual(outline.value(scale), "4 m")
        XCTAssertEqual(line.middle, p(72, 0))
        XCTAssertEqual(area.middle, p(36, 36))
    }

    // Measurements waiting

    private func on(_ document: PdfDocument, _ page: Int) -> Pending {
        Pending(item: MeasureItem(.distance, page, [p(0, 0), p(10, 0)]), key: PageKey.of(document.pages[page]))
    }

    func test_aTurnedPageDropsItsMeasurementsAndTheOthersStay() async throws {
        let document = try PdfDocument.open(Pdfs.text(3))
        let waiting = [on(document, 0), on(document, 2)]

        document.pages[2].dictionary["Rotate"] = PdfNumber(90)

        let kept = Pending.keep(waiting, document)
        XCTAssertEqual(kept.map(\.item.page), [0])
    }

    func test_aDeletedPageMovesTheMeasurementsAfterItUp() async throws {
        let document = try PdfDocument.open(Pdfs.text(3))
        let waiting = [on(document, 0), on(document, 1), on(document, 2)]

        try PageOperations.delete(document, [0])

        let kept = Pending.keep(waiting, document)
        XCTAssertEqual(kept.map(\.item.page), [0, 1])
    }

    func test_aFileOpenedAgainFromTheSameBytesKeepsEverything() async throws {
        let bytes = Pdfs.text(2)
        let waiting = [on(try PdfDocument.open(bytes), 1)]

        XCTAssertEqual(Pending.keep(waiting, try PdfDocument.open(bytes)).count, 1)
    }
}
