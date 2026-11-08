#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import XCTest
import LazyPDFKit
@testable import LazyPDFApp
@testable import LazyPDFUI

// The marks of a page overlay drawn by the Mac document view into a bitmap: they land where page space says at any zoom and
// rotation, keep the sizes that must not grow, and a picture stands the right way up. The model's own tests are in
// LazyPDFAppTests.

private final class NoFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
}

@MainActor
final class PageOverlayPaintTests: XCTestCase {
    private struct Shown {
        let viewer: ViewerModel
        let view: PageDocumentView
    }

    private func open() throws -> Shown {
        let bytes = try PdfFromText.create("Hello from the tests.", fonts: NoFonts()).bytes
        let tab = DocumentTab(session: try PdfEditSession.open(bytes), renderer: PdfKitRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(1400, 1200), pixelsPerDip: 1)
        viewer.show(tab)
        viewer.zoom = 1
        let view = PageDocumentView(viewer: viewer)
        view.frame = NSRect(x: 0, y: 0, width: viewer.extent.width, height: viewer.extent.height)
        return Shown(viewer: viewer, view: view)
    }

    private func bitmap(_ shown: Shown) throws -> NSBitmapImageRep {
        shown.view.frame = NSRect(x: 0, y: 0, width: shown.viewer.extent.width, height: shown.viewer.extent.height)
        let area = NSRect(x: 0, y: 0, width: shown.viewer.viewport.width, height: shown.viewer.viewport.height)
        let rep = try XCTUnwrap(shown.view.bitmapImageRepForCachingDisplay(in: area))
        shown.view.cacheDisplay(in: area, to: rep)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        guard let color = rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 }

    // Pixels in an area of the view that pass the test; the scan is kept to the area because reading a pixel is slow.
    private func count(_ rep: NSBitmapImageRep, in area: ViewRect, _ test: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
        var found = 0
        for y in Swift.max(Int(area.top), 0)..<Swift.min(Int(area.bottom) + 1, rep.pixelsHigh) {
            for x in Swift.max(Int(area.left), 0)..<Swift.min(Int(area.right) + 1, rep.pixelsWide) where test(pixel(rep, Double(x), Double(y))) {
                found += 1
            }
        }
        return found
    }

    // The mark's rectangle in the view, from the viewer's own matrix for the page.
    private func placed(_ shown: Shown, _ area: ViewRect) throws -> ViewRect {
        let matrix = try XCTUnwrap(shown.viewer.pageToView(0))
        let placed = PageSpace.transform(matrix, area)
        XCTAssertTrue(ViewRect(0, 0, shown.viewer.viewport.width, shown.viewer.viewport.height).contains(placed))
        return placed
    }

    private func redBox(_ shown: Shown, _ area: ViewRect) {
        shown.viewer.overlay(0).set(OverlayItem("test.box", .rect(area), style: OverlayStyle(fill: OverlayColor(red: 1, green: 0, blue: 0))))
    }

    private func checkLands(_ shown: Shown, _ area: ViewRect) throws {
        let rep = try bitmap(shown)
        let there = try placed(shown, area)
        let inside = pixel(rep, there.center.x, there.center.y)
        XCTAssertTrue(isRed(inside), "centre is \(inside)")
        for (dx, dy) in [(-4.0, 0.0), (4.0, 0.0), (0.0, -4.0), (0.0, 4.0)] {
            let near = pixel(rep, dx < 0 ? there.left + dx : dx > 0 ? there.right + dx : there.center.x,
                             dy < 0 ? there.top + dy : dy > 0 ? there.bottom + dy : there.center.y)
            XCTAssertFalse(isRed(near), "beside the mark at \(dx), \(dy)")
        }
        let expected = there.width * there.height
        XCTAssertEqual(Double(count(rep, in: there.inflated(20, 20), isRed)), expected, accuracy: expected * 0.05)
    }

    func test_aMarkLandsWhereThePageSpaceSaysAtTwoZooms() throws {
        let shown = try open()
        let area = ViewRect(30, 40, 80, 30)
        redBox(shown, area)

        shown.viewer.zoom = 1
        try checkLands(shown, area)
        shown.viewer.zoom = 2
        try checkLands(shown, area)
    }

    func test_aMarkTurnsWithThePage() throws {
        let shown = try open()
        let area = ViewRect(30, 40, 80, 30)
        redBox(shown, area)
        shown.viewer.rotation = 90

        try checkLands(shown, area)
        let there = try placed(shown, area)
        XCTAssertGreaterThan(there.height, there.width)
    }

    func test_aMarkThatIsRotatedTurnsAboutItsMiddle() throws {
        let shown = try open()
        let area = ViewRect(30, 40, 100, 20)
        shown.viewer.overlay(0).set(OverlayItem("test.box", .rect(area), style: OverlayStyle(fill: OverlayColor(red: 1, green: 0, blue: 0)),
                                                rotation: 90))

        let rep = try bitmap(shown)
        let middle = try placed(shown, area).center
        let scale = try XCTUnwrap(shown.viewer.pageToView(0)).m11

        XCTAssertTrue(isRed(pixel(rep, middle.x, middle.y + 40 * scale)))
        XCTAssertTrue(isRed(pixel(rep, middle.x, middle.y - 40 * scale)))
        XCTAssertFalse(isRed(pixel(rep, middle.x + 40 * scale, middle.y)))
    }

    func test_aMarkerKeepsItsSizeOnTheScreenWhateverTheZoom() throws {
        let shown = try open()
        shown.viewer.overlay(0).set(OverlayItem("test.dot", .marker(center: ViewPoint(60, 60), size: 10, round: false),
                                                style: OverlayStyle(fill: OverlayColor(red: 1, green: 0, blue: 0))))
        var counts: [Int] = []

        for zoom in [1.0, 2.0] {
            shown.viewer.zoom = zoom
            let at = try XCTUnwrap(shown.viewer.pageToView(0)).transform(ViewPoint(60, 60))
            counts.append(count(try bitmap(shown), in: ViewRect(at.x - 30, at.y - 30, 60, 60), isRed))
        }

        XCTAssertEqual(Double(counts[0]), 100, accuracy: 30)
        XCTAssertEqual(Double(counts[1]), 100, accuracy: 30)
    }

    func test_aLineKeepsItsWidthOnTheScreenUnlessItScalesWithThePage() throws {
        let shown = try open()
        let red = OverlayColor(red: 1, green: 0, blue: 0)
        shown.viewer.overlay(0).set(OverlayItem("test.fixed", .line(ViewPoint(20, 60), ViewPoint(120, 60)),
                                                style: OverlayStyle(stroke: red, lineWidth: 4)))
        shown.viewer.overlay(0).set(OverlayItem("test.scaled", .line(ViewPoint(20, 120), ViewPoint(120, 120)),
                                                style: OverlayStyle(stroke: red, lineWidth: 4, scalesWithPage: true)))
        shown.viewer.zoom = 2
        let rep = try bitmap(shown)
        let matrix = try XCTUnwrap(shown.viewer.pageToView(0))
        let fixed = matrix.transform(ViewPoint(70, 60))
        let scaled = matrix.transform(ViewPoint(70, 120))

        func thickness(_ at: ViewPoint) -> Int {
            (-20...20).filter { isRed(pixel(rep, at.x, at.y + Double($0))) }.count
        }

        XCTAssertEqual(Double(thickness(fixed)), 4, accuracy: 1)
        XCTAssertEqual(Double(thickness(scaled)), 4 * matrix.m11, accuracy: 1.5)
    }

    func test_aPictureStandsTheRightWayUp() throws {
        let shown = try open()
        let pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let area = ViewRect(30, 40, 80, 60)
        shown.viewer.overlay(0).set(OverlayItem("test.picture", .picture(OverlayPicture(PdfRgbaImage(2, 2, pixels), rect: area))))

        let rep = try bitmap(shown)
        let there = try placed(shown, area)

        XCTAssertTrue(isRed(pixel(rep, there.center.x, there.top + there.height * 0.25)))
        XCTAssertTrue(isBlue(pixel(rep, there.center.x, there.top + there.height * 0.75)))
    }

    func test_textIsDrawnInsideTheBoxItIsGivenAndFollowsTheZoom() throws {
        let shown = try open()
        let look = OverlayTextLook(family: "Helvetica", size: 20, bold: true, color: OverlayColor(red: 1, green: 0, blue: 0))
        shown.viewer.overlay(0).set(OverlayItem("test.text", .text(OverlayText("MMMM", at: ViewPoint(30, 40), look: look))))
        let dark: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r > 200 && $0.g < 100 }
        var heights: [Int] = []

        for zoom in [1.0, 2.0] {
            shown.viewer.zoom = zoom
            let rep = try bitmap(shown)
            let origin = try XCTUnwrap(shown.viewer.pageToView(0)).transform(ViewPoint(30, 40))
            var rows = Set<Int>()
            for y in Int(origin.y) - 30..<Int(origin.y) + Int(60 * zoom) {
                for x in Int(origin.x) - 30..<Int(origin.x) + Int(200 * zoom) where dark(pixel(rep, Double(x), Double(y))) {
                    XCTAssertGreaterThanOrEqual(Double(x), origin.x - 2)
                    rows.insert(y)
                }
            }
            XCTAssertGreaterThanOrEqual(Double(rows.min() ?? 0), origin.y - 2)
            heights.append(rows.count)
        }

        XCTAssertGreaterThan(heights[0], 8)
        XCTAssertEqual(Double(heights[1]), Double(heights[0]) * 2, accuracy: Double(heights[0]) * 0.25)
    }
}
#endif
#endif
