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

    private func open(pages: Int = 2, line: String = "Hello from the tests.") async throws -> Shown {
        let text = (0..<pages).map { "\(line) Page \($0 + 1)." }.joined(separator: "\u{0C}")
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

    private func pageElements(_ shown: Shown) -> [NSAccessibilityElement] {
        (shown.view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    func test_aQueryFindsTheSameElementsAsTheOneBefore() async throws {
        let shown = try await open()

        let first = pageElements(shown)
        let second = pageElements(shown)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.count, second.count)
        XCTAssertTrue(zip(first, second).allSatisfy { $0 === $1 })
    }

    func test_theElementsAreMadeAgainAfterTheTextIsReset() async throws {
        let shown = try await open()
        let before = pageElements(shown)

        shown.viewer.resetText()
        let after = pageElements(shown)

        XCTAssertEqual(before.count, after.count)
        XCTAssertFalse(before.first === after.first)
    }

    func test_theElementsAreMadeAgainAfterANewRevision() async throws {
        let shown = try await open()
        let before = pageElements(shown)
        let tab = try XCTUnwrap(shown.viewer.tab)
        var metadata = DocumentMetadata.read(tab.session.document)
        metadata.title = "New title"
        try metadata.write(tab.session.document)
        let epoch = shown.viewer.textEpoch

        XCTAssertTrue(try tab.commit("Properties"))
        await until { shown.viewer.textEpoch != epoch }

        XCTAssertFalse(before.first === pageElements(shown).first)
    }

    private func pageText(_ shown: Shown, in window: NSWindow? = nil) async throws -> PageTextElement {
        await shown.viewer.loadPage(0)
        window?.contentView = shown.view
        let group = try XCTUnwrap(pageElements(shown).first as? PageAccessibilityGroup)
        return group.text
    }

    func test_aPageBeyondThePreloadIsReadWhenAScreenReaderAsksForIt() async throws {
        let shown = try await open(pages: 12)
        shown.viewer.zoom = 0.15
        XCTAssertGreaterThan(shown.viewer.visiblePages.count, 8)
        let last = try XCTUnwrap(shown.viewer.visiblePages.last)
        let element = PageTextElement(page: last, view: shown.view)
        XCTAssertNil(element.accessibilityValue())

        await until { element.accessibilityValue() != nil }

        XCTAssertEqual(element.accessibilityValue() as? String, "Hello from the tests. Page \(last + 1).")
    }

    func test_aPageHoldsOneStaticTextWithItsTextInsideTheGroup() async throws {
        let shown = try await open()

        let element = try await pageText(shown)
        let group = try XCTUnwrap(pageElements(shown).first as? PageAccessibilityGroup)

        XCTAssertTrue(group.accessibilityChildren()?.first as? PageTextElement === element)
        XCTAssertEqual(element.accessibilityRole(), .staticText)
        XCTAssertEqual(element.accessibilityValue() as? String, "Hello from the tests. Page 1.")
        XCTAssertEqual(element.accessibilityNumberOfCharacters(), 29)
        XCTAssertEqual(group.accessibilityLabel(), "Page 1 of 2")
    }

    func test_linesAndRangesAreAnsweredInUnitsOfTheText() async throws {
        let shown = try await open(pages: 1, line: "First line\nSecond line here")
        let element = try await pageText(shown)
        let value = try XCTUnwrap(element.accessibilityValue() as? String)

        XCTAssertEqual(value, "First line\nSecond line here Page 1.")
        XCTAssertEqual(element.accessibilityRange(forLine: 1), NSRange(location: 11, length: 24))
        XCTAssertEqual(element.accessibilityLine(for: 3), 0)
        XCTAssertEqual(element.accessibilityLine(for: 12), 1)
        XCTAssertEqual(element.accessibilityString(for: NSRange(location: 11, length: 6)), "Second")
        XCTAssertEqual(element.accessibilityRange(for: 13), NSRange(location: 13, length: 1))
        XCTAssertEqual(element.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: value.utf16.count))
    }

    func test_aScreenReaderSetsTheSelectionAndReadsItBack() async throws {
        let shown = try await open(pages: 1, line: "First line\nSecond line here")
        let element = try await pageText(shown)
        XCTAssertEqual(element.accessibilitySelectedTextRange().location, NSNotFound)

        element.setAccessibilitySelectedTextRange(NSRange(location: 11, length: 6))

        XCTAssertTrue(shown.viewer.hasSelection)
        XCTAssertEqual(element.accessibilitySelectedTextRange(), NSRange(location: 11, length: 6))
        XCTAssertEqual(element.accessibilitySelectedText(), "Second")
        let copied = await shown.viewer.selectedText()
        XCTAssertEqual(copied, "Second")
    }

    func test_aCaretOnALineBreakIsReadBackAsPlaced() async throws {
        let shown = try await open(pages: 1, line: "First line\nSecond line here")
        let element = try await pageText(shown)

        element.setAccessibilitySelectedTextRange(NSRange(location: 10, length: 0))

        XCTAssertEqual(element.accessibilitySelectedTextRange(), NSRange(location: 10, length: 0))
        XCTAssertFalse(shown.viewer.hasSelection)
    }

    func test_aSelectionFromAnotherPartOfTheViewerShowsInTheElement() async throws {
        let shown = try await open(pages: 1)
        let element = try await pageText(shown)

        shown.viewer.selectAll()

        XCTAssertEqual(element.accessibilitySelectedTextRange(), NSRange(location: 0, length: 29))
    }

    func test_aRangeHasAPlaceOnTheScreenAndThePlaceFindsTheRangeAgain() async throws {
        let shown = try await open(pages: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let element = try await pageText(shown, in: window)

        let frame = element.accessibilityFrame(for: NSRange(location: 6, length: 4))

        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(element.accessibilityFrame().width, frame.width)
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertGreaterThan(NSIntersectionRange(NSRange(location: 6, length: 4), element.accessibilityRange(for: middle)).length, 0)
    }

    func test_theMenuOffersCopyLookUpShareAndSelectAll() async throws {
        let shown = try await open()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        let menu = try XCTUnwrap(shown.view.menu(for: event))

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Look Up", "Share", "", "Highlight", "Underline", "Note", "Redact", "", "Select all"])
        XCTAssertFalse(shown.view.validateMenuItem(menu.items[1]))
        XCTAssertFalse(shown.view.validateMenuItem(menu.items[4]))
        XCTAssertTrue(shown.view.validateMenuItem(try XCTUnwrap(menu.items.last)))
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
