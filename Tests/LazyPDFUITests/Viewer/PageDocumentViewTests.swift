#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import XCTest
import LazyPDFKit
@testable import LazyPDFApp
@testable import LazyPDFUI

// The Mac document view drawn into a bitmap, from a real file through PDFKit: the paper white, ink where the text is, a mark
// where a search hit is. The model's own tests are in LazyPDFAppTests.

private final class NoFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
}

@MainActor
private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
}

@MainActor
final class PageDocumentViewTests: XCTestCase {
    private struct Shown {
        let viewer: ViewerModel
        let view: PageDocumentView
    }

    private func open(pages: Int = 2) async throws -> Shown {
        let text = (0..<pages).map { "Hello from the tests. Page \($0 + 1)." }.joined(separator: "\u{0C}")
        let bytes = try PdfFromText.create(text, fonts: NoFonts()).bytes
        let tab = DocumentTab(session: try PdfEditSession.open(bytes), renderer: PdfKitRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(900, 700), pixelsPerDip: 1)
        viewer.show(tab)
        viewer.zoom = 1
        let view = PageDocumentView(viewer: viewer)
        view.frame = NSRect(x: 0, y: 0, width: viewer.extent.width, height: viewer.extent.height)
        // The sharp tiles of the page in view have all come when the pictures are only they.
        await until { viewer.tilesPending == 0 && viewer.drawing(of: 0).pictures.count >= 4 }
        return Shown(viewer: viewer, view: view)
    }

    private func bitmap(_ shown: Shown) throws -> NSBitmapImageRep {
        let area = NSRect(x: 0, y: 0, width: shown.viewer.viewport.width, height: shown.viewer.viewport.height)
        let rep = try XCTUnwrap(shown.view.bitmapImageRepForCachingDisplay(in: area))
        shown.view.cacheDisplay(in: area, to: rep)
        return rep
    }

    // The pixel at a point of the view, as red, green and blue from 0 to 255.
    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    // The part of the view that a stretch of the page's text covers, from the engine's boxes for its characters.
    private func box(_ shown: Shown, characters: Range<Int>) async throws -> CGRect {
        let loaded = await shown.viewer.text(0)
        let text = try XCTUnwrap(loaded)
        let matrix = try XCTUnwrap(shown.viewer.pageToView(0))
        let geometry = shown.viewer.geometry(0)
        var area = CGRect.null
        for i in characters {
            let bounds = text.chars[i].quad.bounds
            let a = matrix.transform(point(geometry.toDisplay(bounds.left, bounds.bottom)))
            let b = matrix.transform(point(geometry.toDisplay(bounds.right, bounds.top)))
            area = area.union(CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        return area
    }

    private func point(_ p: (x: Double, y: Double)) -> ViewPoint {
        ViewPoint(p.x, p.y)
    }

    private func count(_ rep: NSBitmapImageRep, in area: CGRect, where test: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
        var found = 0
        for y in Int(area.minY)...Int(area.maxY) {
            for x in Int(area.minX)...Int(area.maxX) where test(pixel(rep, x, y)) { found += 1 }
        }
        return found
    }

    func test_thePageIsWhiteWithInkWhereTheTextIs() async throws {
        let shown = try await open()
        let rep = try bitmap(shown)
        let page = try XCTUnwrap(shown.viewer.pageToView(0))
        let corner = page.transform(ViewPoint(8, 8))
        let text = try await box(shown, characters: 0..<5)

        let paper = pixel(rep, Int(corner.x), Int(corner.y))
        XCTAssertGreaterThan(Swift.min(paper.r, paper.g, paper.b), 250)
        XCTAssertGreaterThan(count(rep, in: text) { $0.r < 100 && $0.g < 100 && $0.b < 100 }, 10)
        // Below the one line of text the page is blank.
        XCTAssertEqual(count(rep, in: text.offsetBy(dx: 0, dy: 200)) { $0.r < 200 }, 0)
    }

    func test_aSearchHitIsMarkedWhereTheMatchIs() async throws {
        let shown = try await open()
        let before = try bitmap(shown)
        let hit = try await box(shown, characters: 0..<5)
        let marked: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r > 200 && $0.r - $0.b > 60 }
        XCTAssertEqual(count(before, in: hit, where: marked), 0)

        await shown.viewer.search.start("Hello", TextSearchOptions()).value
        let after = try bitmap(shown)

        XCTAssertEqual(shown.viewer.search.hits.count, 2)
        XCTAssertGreaterThan(count(after, in: hit, where: marked), Int(hit.width * hit.height / 4))
        // The other page's hit is not in view; the paper beside the match is untouched.
        let beside = hit.offsetBy(dx: 0, dy: -hit.height * 3)
        XCTAssertEqual(count(after, in: beside, where: marked), 0)
    }

    func test_aSelectionIsMarkedInTheAccentColour() async throws {
        let shown = try await open()
        let hit = try await box(shown, characters: 0..<5)
        let tinted: ((r: Int, g: Int, b: Int)) -> Bool = { $0.b - $0.r > 40 }
        XCTAssertEqual(count(try bitmap(shown), in: hit, where: tinted), 0)

        shown.viewer.selectAll()
        await until { shown.viewer.pageText(0) != nil }
        let rep = try bitmap(shown)

        XCTAssertGreaterThan(count(rep, in: hit, where: tinted), Int(hit.width * hit.height / 4))
    }

    func test_eachPageInViewIsAnAccessibilityElementNamedByItsPlace() async throws {
        let shown = try await open()

        let names = (shown.view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }

        XCTAssertEqual(names.first, "Page 1 of 2")
    }

    func test_theScrollViewAndTheModelFollowEachOther() async throws {
        let shown = try await open(pages: 3)
        let scroll = PageScrollView(viewer: shown.viewer)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(shown.viewer.viewport.width, 0)
        XCTAssertLessThanOrEqual(shown.viewer.viewport.width, 800)
        XCTAssertEqual(scroll.pages.frame.size.height, shown.viewer.extent.height, accuracy: 0.5)

        shown.viewer.scroll(by: 0, 120)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, shown.viewer.offset.y, accuracy: 0.5)
        XCTAssertGreaterThan(shown.viewer.offset.y, 0)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(shown.viewer.offset.y, 300, accuracy: 0.5)
    }
}
#endif
#endif
