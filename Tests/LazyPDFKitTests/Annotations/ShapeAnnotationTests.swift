import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/ShapeAnnotationTests.cs: the same cases. ShapesReopenInPdfPig keeps the
// reopening and drops the PdfPig reading of the annotation types.

final class ShapeAnnotationTests: XCTestCase {
    private let slack = 2.5

    private func start() throws -> (document: PdfDocument, writer: PdfAnnotationWriter, page: PdfPage) {
        let document = try AnnotationFixtures.blank()
        return (document, PdfAnnotationWriter(document), document.pages[0])
    }

    func test_squareStrokesInsideItsRectangle() throws {
        let (document, writer, page) = try start()
        let square = try writer.addSquare(page, PdfRect(100, 600, 200, 650), style: AnnotationStyle(color: [0, 0, 1], width: 4, fill: [1, 1, 0]), info: AnnotationInfo(author: "A"))
        let recorder = try AnnotationFixtures.draw(document, square)
        XCTAssertEqual(recorder.paths.count, 1)
        let path = try XCTUnwrap(recorder.paths.first).path
        XCTAssertEqual(path.operator, "B")
        XCTAssertEqual(path.bounds, PdfRect(2, 2, 98, 48))
        XCTAssertEqual(square.color, [0, 0, 1])
        XCTAssertEqual(square.interiorColor, [1, 1, 0])
        XCTAssertEqual(square.border.width, 4)
    }

    func test_circleIsFourCurves() throws {
        let (document, writer, page) = try start()
        let circle = try writer.addCircle(page, PdfRect(100, 600, 160, 660))
        let recorder = try AnnotationFixtures.draw(document, circle)
        XCTAssertEqual(recorder.paths.count, 1)
        let path = try XCTUnwrap(recorder.paths.first).path
        XCTAssertEqual(path.operator, "S")
        XCTAssertEqual(path.segments.filter { $0.kind == .curve }.count, 4)
        XCTAssertEqual(path.bounds.width, 59, accuracy: 0.1)
    }

    func test_zeroWidthWithoutFillDrawsNothing() throws {
        let (document, writer, page) = try start()
        let square = try writer.addSquare(page, PdfRect(100, 600, 200, 650), style: AnnotationStyle(width: 0))
        XCTAssertFalse(try AnnotationFixtures.draw(document, square).paths.contains { $0.path.stroke || $0.path.fill })
    }

    func test_dashedBorderSetsTheDashPattern() throws {
        let (document, writer, page) = try start()
        let square = try writer.addSquare(page, PdfRect(100, 600, 200, 650), style: AnnotationStyle(dash: [4, 2]))
        XCTAssertEqual(square.border.style, .dashed)
        XCTAssertEqual(square.border.dash, [4, 2])
        let dashes = try AnnotationFixtures.appearance(document, square).filter { $0.operator == "d" }
        XCTAssertEqual(dashes.count, 1)
        XCTAssertEqual((dashes[0].operands[0] as? PdfArray)?.items.count, 2)
    }

    func test_cloudBorderMakesScallopsWithinTheBox() throws {
        for kind in [AnnotationType.square, .circle] {
            let (document, writer, page) = try start()
            let rect = PdfRect(100, 600, 260, 700)
            let cloud = kind == .square
                ? try writer.addSquare(page, rect, style: AnnotationStyle(cloud: 2))
                : try writer.addCircle(page, rect, style: AnnotationStyle(cloud: 2))
            XCTAssertEqual(cloud.cloud, 2, "\(kind)")
            XCTAssertEqual(cloud.rectDifference.count, 4, "\(kind)")
            let recorder = try AnnotationFixtures.draw(document, cloud)
            XCTAssertEqual(recorder.paths.count, 1, "\(kind)")
            let path = try XCTUnwrap(recorder.paths.first).path
            XCTAssertTrue(path.segments.filter { $0.kind == .curve }.count > 20, "\(kind)")
            // The arcs stay inside the appearance's box, or the viewer would clip them. The bounds count control points,
            // which stand a third further out than the curve does.
            XCTAssertTrue(path.bounds.left >= -slack && path.bounds.bottom >= -slack, "\(kind)")
            XCTAssertTrue(path.bounds.right <= rect.width + slack && path.bounds.top <= rect.height + slack, "\(kind)")
        }
    }

    func test_cloudPolygonBulgesOutwardWhicheverWayItIsDrawn() throws {
        let (document, writer, page) = try start()
        let ccw: [PdfPoint] = [(100, 600), (200, 600), (200, 700), (100, 700)]
        for points in [ccw, Array(ccw.reversed())] {
            let cloud = try writer.addCloud(page, points)
            let recorder = try AnnotationFixtures.draw(document, cloud)
            XCTAssertEqual(recorder.paths.count, 1)
            let bounds = try XCTUnwrap(recorder.paths.first).path.bounds
            XCTAssertTrue(bounds.width > 100 + 3, "the arcs should stick out past the corners")
            XCTAssertTrue(bounds.right <= cloud.rect.width + slack && bounds.left >= -slack)
            XCTAssertEqual(document.name(cloud.dictionary, "IT"), "PolygonCloud")
            XCTAssertEqual(cloud.cloud, 1)
        }
    }

    func test_lineDrawsFromOnePointToTheOther() throws {
        let (document, writer, page) = try start()
        let line = try writer.addLine(page, (100, 600), (300, 650), style: AnnotationStyle(width: 2))
        XCTAssertEqual(line.line, [100, 600, 300, 650])
        let recorder = try AnnotationFixtures.draw(document, line)
        XCTAssertEqual(recorder.paths.count, 1)
        let path = try XCTUnwrap(recorder.paths.first).path
        XCTAssertEqual(path.segments.count, 2)
        XCTAssertEqual(path.segments[0].x1, 100 - line.rect.left, accuracy: 5e-4)
        XCTAssertEqual(path.segments[1].y1, 650 - line.rect.bottom, accuracy: 5e-4)
    }

    func test_everyLineEndingIsDrawnAndKeptInsideTheBox() throws {
        let endings: [LineEnding] = [.square, .circle, .diamond, .openArrow, .closedArrow, .butt, .rOpenArrow, .rClosedArrow, .slash]
        for ending in endings {
            let (document, writer, page) = try start()
            let line = try writer.addLine(page, (100, 600), (300, 650), style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [0, 1, 0]), info: nil, start: ending, end: ending)
            XCTAssertEqual(line.startEnding, ending)
            XCTAssertEqual(line.endEnding, ending)
            let recorder = try AnnotationFixtures.draw(document, line)
            XCTAssertEqual(recorder.paths.count, 3, "\(ending)")
            for (path, _) in recorder.paths {
                XCTAssertTrue(path.bounds.left >= -0.01 && path.bounds.bottom >= -0.01, "\(ending)")
                XCTAssertTrue(path.bounds.right <= line.rect.width + 0.01 && path.bounds.top <= line.rect.height + 0.01, "\(ending)")
            }
            let closed = [LineEnding.closedArrow, .rClosedArrow, .square, .circle, .diamond].contains(ending)
            XCTAssertEqual(closed, recorder.paths.dropFirst().allSatisfy { $0.path.fill }, "\(ending)")
        }
    }

    func test_arrowHeadSitsAtTheEndPoint() throws {
        let (document, writer, page) = try start()
        let arrow = try writer.addArrow(page, (100, 600), (300, 600), style: AnnotationStyle(width: 2))
        XCTAssertEqual(document.name(arrow.dictionary, "IT"), "LineArrow")
        XCTAssertEqual(arrow.endEnding, .openArrow)
        let head = try XCTUnwrap(try AnnotationFixtures.draw(document, arrow).paths.last).path
        let tip = head.segments[1]
        XCTAssertEqual(tip.x1, 300 - arrow.rect.left, accuracy: 5e-4)
        XCTAssertEqual(tip.y1, 600 - arrow.rect.bottom, accuracy: 5e-4)
        XCTAssertTrue(head.segments[0].x1 < tip.x1)
    }

    func test_polyLineAndPolygonUseTheirVertices() throws {
        let (document, writer, page) = try start()
        let points: [PdfPoint] = [(100, 600), (150, 650), (200, 600), (250, 650)]
        let polyline = try writer.addPolyLine(page, points, style: AnnotationStyle(color: [0, 0, 1]), info: nil, start: .none, end: .closedArrow)
        let polygon = try writer.addPolygon(page, points, style: AnnotationStyle(color: [0, 0, 1], fill: [1, 0.8, 0.8]))
        XCTAssertEqual(polyline.vertices.count, 8)
        XCTAssertEqual(polyline.type, .polyLine)
        XCTAssertEqual(polygon.type, .polygon)
        XCTAssertEqual(try AnnotationFixtures.draw(document, polyline).paths[0].path.segments.count, 4)
        let recorder = try AnnotationFixtures.draw(document, polygon)
        XCTAssertEqual(recorder.paths.count, 1)
        let filled = try XCTUnwrap(recorder.paths.first).path
        XCTAssertEqual(filled.operator, "B")
        XCTAssertEqual(filled.segments.count, 5)
    }

    func test_inkStrokesAreSmoothedWithRoundCaps() throws {
        let (document, writer, page) = try start()
        let stroke: [PdfPoint] = [(100, 600), (110, 620), (130, 625), (150, 610), (170, 640)]
        let ink = try writer.addInk(page, [stroke, [(300, 600)]], style: AnnotationStyle(color: [0, 0, 0], width: 3))
        XCTAssertEqual(ink.inkList.count, 2)
        XCTAssertEqual(ink.inkList[0].count, 10)
        let ops = try AnnotationFixtures.appearance(document, ink)
        XCTAssertTrue(ops.contains { $0.operator == "J" })
        XCTAssertTrue(ops.contains { $0.operator == "c" })
        XCTAssertEqual(ops.filter { $0.operator == "S" }.count, 2)
    }

    func test_opacityGoesIntoTheAppearance() throws {
        let (document, writer, page) = try start()
        let ink = try writer.addInk(page, [[(100, 600), (120, 640)]], style: AnnotationStyle(opacity: 0.4))
        XCTAssertEqual(ink.opacity, 0.4)
        let resources = document.dict(try AnnotationFixtures.normal(document, ink).dictionary, "Resources")
        let state = try XCTUnwrap(document.dict(document.dict(resources, "ExtGState"), "GS1"))
        XCTAssertEqual(document.number(state, "CA"), 0.4)
        XCTAssertEqual(document.name(state, "BM"), "Normal")
    }

    func test_shapesReopen() throws {
        let (document, writer, page) = try start()
        try writer.addSquare(page, PdfRect(10, 10, 60, 60))
        try writer.addCircle(page, PdfRect(70, 10, 120, 60))
        try writer.addLine(page, (10, 100), (100, 120))
        try writer.addPolygon(page, [(10, 200), (50, 250), (90, 200)])
        try writer.addInk(page, [[(10, 300), (20, 320)]])
        let reopened = try AnnotationFixtures.reopen(document)
        XCTAssertEqual(PdfAnnotations.read(reopened, reopened.pages[0]).map { $0.type }, [.square, .circle, .line, .polygon, .ink])
    }

    func test_refusesDegenerateInput() throws {
        let (_, writer, page) = try start()
        func refused(_ call: () throws -> Any) {
            XCTAssertThrowsError(try call()) { XCTAssertTrue($0 is ArgumentException) }
        }
        refused { try writer.addPolygon(page, [(1, 1), (2, 2)]) }
        refused { try writer.addPolyLine(page, [(1, 1)]) }
        refused { try writer.addInk(page, []) }
        refused { try writer.addSquare(page, PdfRect(5, 5, 5, 5), style: AnnotationStyle(width: 0)) }
        refused { try writer.addStamp(page, PdfRect(5, 5, 5, 5), "Draft") }
        refused { try writer.addFreeText(page, PdfRect(5, 5, 5, 5), "x") }
        refused { try writer.addImageStamp(page, PdfRect(5, 5, 5, 5), 1, 1, [0, 0, 0, 255]) }
    }

    func test_cloudBorderOfAnInfiniteEdgeStaysSmall() {
        let corners: [PdfPoint] = [(-.infinity, 0), (10, 0), (10, 50), (-.infinity, 50)]
        XCTAssertEqual(CloudBorder.resample(corners, 10).count, 4)
        XCTAssertEqual(CloudBorder.rectPoints(-.infinity, 0, 10, 50, 10).count, 4)
    }
}
