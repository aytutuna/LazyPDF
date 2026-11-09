import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/measure/MeasureWriterTests.cs: measurements written into a real file and read back
// by the engine. The last test sets the locale of the numbers where the Windows one sets the culture.

final class MeasureWriterTests: XCTestCase {
    private let scale = MeasureScale(1, .inch, 10, .metre)
    private let date = DateTimeOffset(2026, 1, 5, 9, 0, 0)

    private let line = MeasureItem(.distance, 0, [ViewPoint(100, 100), ViewPoint(172, 100)])
    private let room = MeasureItem(.area, 0, [ViewPoint(100, 200), ViewPoint(172, 200), ViewPoint(172, 272), ViewPoint(100, 272)])

    private func reopen(_ session: PdfEditSession) throws -> (document: PdfDocument, marks: [PdfAnnotation]) {
        let reopened = try PdfDocument.open(session.current)
        return (reopened, PdfAnnotations.read(reopened, reopened.pages[0]))
    }

    private func writeAndReopen(_ items: [MeasureItem]) throws -> (document: PdfDocument, marks: [PdfAnnotation]) {
        let session = try PdfEditSession.open(Pdfs.text())
        let count = try MeasureWriter.write(session.document, items, scale, author: "Sam", date: date)
        XCTAssertEqual(count, items.count)
        XCTAssertTrue(try session.commit("Measure"))
        return try reopen(session)
    }

    private func entry(_ document: PdfDocument, _ measure: PdfDictionary, _ key: String) throws -> PdfDictionary {
        let formats = try XCTUnwrap(document.resolve(measure[key]) as? PdfArray)
        XCTAssertEqual(formats.items.count, 1)
        return try XCTUnwrap(document.resolve(formats.items[0]) as? PdfDictionary)
    }

    private func factor(_ document: PdfDocument, _ measure: PdfDictionary, _ key: String) throws -> Double {
        try XCTUnwrap((document.resolve(try entry(document, measure, key)["C"]) as? PdfNumber)?.value)
    }

    func test_aDistanceIsALineWithItsScale() throws {
        let (document, all) = try writeAndReopen([line])

        let lines = all.filter { $0.type == .line }
        XCTAssertEqual(lines.count, 1)
        let made = lines[0]
        XCTAssertEqual(made.contents, "Distance: 10 m")
        XCTAssertEqual(made.title, "Sam")
        XCTAssertEqual(made.line.count, 4)
        let measure = try XCTUnwrap(document.resolve(made.dictionary["Measure"]) as? PdfDictionary)
        XCTAssertEqual((measure["Type"] as? PdfName)?.value, "Measure")
        XCTAssertEqual((measure["Subtype"] as? PdfName)?.value, "RL")
        let x = try entry(document, measure, "X")
        XCTAssertEqual(try factor(document, measure, "X"), 10.0 / 72, accuracy: 1e-9)
        XCTAssertEqual(PdfText.read(document, x, "U"), "m")
        XCTAssertEqual(try factor(document, measure, "D"), 1)
        XCTAssertEqual(try factor(document, measure, "A"), 1)
    }

    func test_xFollowsTheUserUnitOfThePageAndNothingElseDoes() throws {
        let session = try PdfEditSession.open(Pdfs.text())
        session.document.pages[0].dictionary["UserUnit"] = PdfNumber(2)
        _ = try MeasureWriter.write(session.document, [line], scale, author: "Sam", date: date)
        try session.commit("Measure")

        let (document, all) = try reopen(session)
        let made = try XCTUnwrap(all.first { $0.type == .line })
        let measure = try XCTUnwrap(document.resolve(made.dictionary["Measure"]) as? PdfDictionary)
        XCTAssertEqual(try factor(document, measure, "X"), 2 * 10.0 / 72, accuracy: 1e-9)
        XCTAssertEqual(try factor(document, measure, "D"), 1)
        XCTAssertTrue(try XCTUnwrap(made.contents).hasSuffix("10 m"))
    }

    func test_aPerimeterIsAnOpenPolylineThatComesBackToItsStart() throws {
        let walk = MeasureItem(.perimeter, 0, [ViewPoint(100, 100), ViewPoint(172, 100), ViewPoint(172, 172)])

        let (document, all) = try writeAndReopen([walk])

        let polylines = all.filter { $0.type == .polyLine }
        XCTAssertEqual(polylines.count, 1)
        let made = polylines[0]
        XCTAssertEqual((document.resolve(made.dictionary["IT"]) as? PdfName)?.value, "PolyLineDimension")
        XCTAssertEqual(made.vertices.count / 2, 4)
        XCTAssertEqual(made.vertices[0], made.vertices[6], accuracy: 1e-6)
        XCTAssertEqual(made.vertices[1], made.vertices[7], accuracy: 1e-6)
        XCTAssertFalse(all.contains { $0.type == .polygon })
    }

    func test_anAreaIsAPolygonWithItsIntent() throws {
        let (document, all) = try writeAndReopen([room])

        let polygons = all.filter { $0.type == .polygon }
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual((document.resolve(polygons[0].dictionary["IT"]) as? PdfName)?.value, "PolygonDimension")
        XCTAssertEqual(polygons[0].contents, "Area: 100 m²")
        XCTAssertEqual(all.filter { $0.type == .freeText }.count, 1)
    }

    func test_onATurnedPageTheValueBoxIsShownUprightWhereTheMiddleIs() throws {
        let session = try PdfEditSession.open(Pdfs.text())
        session.document.pages[0].dictionary["Rotate"] = PdfNumber(90)
        _ = try MeasureWriter.write(session.document, [line], scale, author: "Sam", date: date)
        try session.commit("Measure")

        let (document, all) = try reopen(session)
        let label = try XCTUnwrap(all.first { $0.type == .freeText })
        let shown = PageGeometry(document.pages[0]).toDisplay(label.rect)
        XCTAssertGreaterThan(shown.width, shown.height)
        XCTAssertEqual(shown.x + shown.width / 2, 136, accuracy: 1e-6)
        XCTAssertEqual(shown.y + shown.height / 2, 100, accuracy: 1e-6)
        let ap = try XCTUnwrap(document.resolve(label.dictionary["AP"]) as? PdfDictionary)
        let form = try XCTUnwrap(document.resolve(ap["N"]) as? PdfStream)
        let matrix = try XCTUnwrap(document.resolve(form.dictionary["Matrix"]) as? PdfArray)
        XCTAssertEqual(matrix.items.compactMap { ($0 as? PdfNumber)?.value }, [0, 1, -1, 0, 0, 0])
    }

    func test_aMeasurementOnAPageThatIsGoneWritesNothing() throws {
        let session = try PdfEditSession.open(Pdfs.text())
        let gone = MeasureItem(.distance, 4, [ViewPoint(0, 0), ViewPoint(10, 0)])

        XCTAssertThrowsError(try MeasureWriter.write(session.document, [line, gone], scale, author: "Sam", date: date)) {
            XCTAssertTrue($0 is ArgumentException)
        }

        XCTAssertFalse(try session.commit("Measure"))
    }

    func test_aGroupSeparatorThatNoStandardFontHasDoesNotCostTheValueBox() throws {
        let before = MeasureScale.locale
        MeasureScale.locale = Locale(identifier: "fr_FR")
        defer { MeasureScale.locale = before }
        let odd = MeasureScale(1, .inch, 1234, .millimetre)
        let session = try PdfEditSession.open(Pdfs.text())
        let item = MeasureItem(.distance, 0, [ViewPoint(0, 0), ViewPoint(72, 0)])

        _ = try MeasureWriter.write(session.document, [item], odd, author: "Sam", date: date, fonts: FakeFonts())
        try session.commit("Measure")

        let (_, all) = try reopen(session)
        let labels = all.filter { $0.type == .freeText }
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].contents, "1 234 mm")
    }
}
