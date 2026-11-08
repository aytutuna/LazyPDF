import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The layer of marks a tool draws on a page (windows/LazyPDF.App/Viewer/PageOverlay.cs): what the viewer keeps for each page,
// how marks replace and leave, and how a field ends. The painting is in LazyPDFUITests.

// Reports the size the page has in the document, as a renderer does, so a turned page changes size.
private final class SizedRenderer: DocumentRenderer {
    private var session: PdfEditSession?

    func load(_ session: PdfEditSession, _ password: String?) -> Bool {
        self.session = session
        return true
    }

    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) {
        guard let page = session?.document.pages[pageIndex] else { return (0, 0) }
        let geometry = PageGeometry(page)
        return (geometry.width, geometry.height)
    }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    func close() {}
}

@MainActor
final class PageOverlayTests: XCTestCase {
    private func open(pages: Int = 3) throws -> (viewer: ViewerModel, tab: DocumentTab) {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(pages)), renderer: SizedRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { SizedRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        return (viewer, tab)
    }

    private func box(_ id: String, layer: Int = 0) -> OverlayItem {
        OverlayItem(id, .rect(ViewRect(10, 10, 50, 20)), layer: layer)
    }

    func test_theViewerKeepsOneLayerForEachPageAsLongAsTheDocumentIsShown() throws {
        let (viewer, tab) = try open()
        let first = viewer.overlay(1)

        XCTAssertTrue(first === viewer.overlay(1))
        XCTAssertEqual(first.page, 1)
        XCTAssertEqual(first.size, viewer.pageSize(1))

        viewer.show(tab)

        XCTAssertFalse(first === viewer.overlay(1))
    }

    func test_aLayerIsTheSizeOfItsPageAndFollowsAChangeOfPages() throws {
        let (viewer, tab) = try open(pages: 2)
        let layer = viewer.overlay(1)
        let before = layer.size

        PageOperations.rotate(tab.document, [1], 90)
        try tab.commit("Rotate")
        viewer.reload()

        XCTAssertEqual(layer.size, ViewSize(before.height, before.width))
        XCTAssertEqual(layer.size, viewer.pageSize(1))
        XCTAssertTrue(layer === viewer.overlay(1))
    }

    func test_aLayerOfAPageThatWentIsDropped() throws {
        let (viewer, tab) = try open(pages: 2)
        let layer = viewer.overlay(1)
        layer.set(box("a"))

        try PageOperations.delete(tab.document, [1])
        try tab.commit("Delete")
        viewer.reload()

        XCTAssertTrue(layer.items.isEmpty)
        XCTAssertFalse(layer === viewer.overlay(1))
    }

    func test_aMarkWithTheIdOfAnotherReplacesItWhereItStood() throws {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        layer.set(box("a"))
        layer.set(box("b"))

        layer.set(OverlayItem("a", .rect(ViewRect(0, 0, 5, 5))))

        XCTAssertEqual(layer.items.map(\.id), ["a", "b"])
        guard case .rect(let area) = layer.item("a")!.shape else { return XCTFail("not a rectangle") }
        XCTAssertEqual(area, ViewRect(0, 0, 5, 5))
    }

    func test_marksArePaintedByLayerThenByWhenTheyCame() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        layer.set(box("front", layer: 1))
        layer.set(box("first"))
        layer.set(box("behind", layer: -1))
        layer.set(box("second"))

        XCTAssertEqual(layer.painted.map(\.id), ["behind", "first", "second", "front"])
    }

    func test_marksLeaveOneByOneByPrefixAndAllAtOnce() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        for id in ["measure.a", "measure.b", "crop.frame"] { layer.set(box(id)) }

        layer.remove("crop.frame")
        XCTAssertEqual(layer.items.count, 2)
        layer.remove(prefix: "measure.")
        XCTAssertTrue(layer.items.isEmpty)
        layer.set(box("x"))
        layer.removeAll()
        XCTAssertTrue(layer.items.isEmpty)
    }

    func test_theViewerIsToldToDrawAgainWhenAMarkChanges() throws {
        let (viewer, _) = try open()
        var redraws = 0
        viewer.onRedraw = { redraws += 1 }
        let layer = viewer.overlay(0)

        layer.set(box("a"))
        layer.remove("a")
        layer.remove("a")

        XCTAssertEqual(redraws, 2)
    }

    func test_aFieldKeepsWhatWasTypedWhenItCommits() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        var heard: [String?] = []
        let field = layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40), text: "old") { heard.append($0) })

        field.typed("new")
        field.commit("new text")
        field.commit("again")
        field.drop()

        XCTAssertEqual(heard, ["new text"])
        XCTAssertTrue(field.isClosed)
        XCTAssertTrue(layer.fields.isEmpty)
    }

    func test_aDroppedFieldKeepsNothing() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        var heard: [String?] = []
        let field = layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { heard.append($0) })

        field.typed("draft")
        field.drop()

        XCTAssertEqual(heard.count, 1)
        XCTAssertNil(heard[0])
    }

    func test_finishingAFieldHandsInTheTextTypedSoFar() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        var heard: [String?] = []
        let field = layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { heard.append($0) })
        var live: [String] = []
        field.onChange = { live.append($0) }

        field.typed("a")
        field.typed("ab")
        field.typed("ab")
        field.finish()

        XCTAssertEqual(live, ["a", "ab"])
        XCTAssertEqual(heard, ["ab"])
    }

    func test_openingAFieldWithTheIdOfAnOpenOneDropsTheOldOne() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        var first: [String?] = []
        layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { first.append($0) })

        let second = layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { _ in })

        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first[0])
        XCTAssertTrue(layer.fields.first === second)
    }

    func test_aFieldIsDroppedWithItsDocument() throws {
        let (viewer, tab) = try open()
        var heard: [String?] = []
        viewer.overlay(0).open(OverlayField("note", area: ViewRect(0, 0, 100, 40), text: "x") { heard.append($0) })

        tab.dispose()
        viewer.show(nil)

        XCTAssertEqual(heard.count, 1)
        XCTAssertNil(heard[0])
    }

    func test_aFieldKeepsItsTextWhenTheViewerLeavesADocumentThatStaysOpen() throws {
        let (viewer, tab) = try open()
        var heard: [String?] = []
        let field = viewer.overlay(0).open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { heard.append($0) })
        field.typed("typed")

        viewer.show(nil)

        XCTAssertEqual(heard, ["typed"])
        XCTAssertFalse(tab.isDisposed)
    }

    func test_endingAToolsMarksFinishesItsFieldsAndRemovesItsItemsOnTheLayersThatExist() throws {
        let (viewer, _) = try open()
        var heard: [String?] = []
        let layer = viewer.overlay(1)
        layer.set(box("comment.a"))
        layer.set(box("measure.a"))
        layer.open(OverlayField("comment.note", area: ViewRect(0, 0, 10, 10), text: "kept") { heard.append($0) })
        layer.open(OverlayField("measure.note", area: ViewRect(0, 0, 10, 10)) { _ in })

        viewer.endToolMarks(prefix: "comment.")

        XCTAssertEqual(heard, ["kept"])
        XCTAssertEqual(layer.items.map(\.id), ["measure.a"])
        XCTAssertEqual(layer.fields.map(\.id), ["measure.note"])
        XCTAssertEqual(viewer.openFields.count, 1)
    }

    func test_endingAToolsMarksMakesNoLayerForAPageItNeverDrewOn() throws {
        let (viewer, _) = try open()

        viewer.endToolMarks(prefix: "comment.")

        XCTAssertTrue(viewer.openFields.isEmpty)
        XCTAssertEqual(viewer.overlay(2).items.count, 0)
    }

    func test_settingTheTextOfAFieldRedrawsAndTypingInItDoesNot() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        let field = layer.open(OverlayField("note", area: ViewRect(0, 0, 100, 40)) { _ in })
        let before = layer.revision

        field.text = "set"
        XCTAssertGreaterThan(layer.revision, before)

        let after = layer.revision
        field.typed("typed")
        XCTAssertEqual(layer.revision, after)
        XCTAssertEqual(field.text, "typed")
    }

    func test_aFieldWithALimitRefusesWhatWouldPassIt() {
        let field = OverlayField("pin", area: ViewRect(0, 0, 100, 40), maxLength: 4) { _ in }

        XCTAssertTrue(field.accepts("123", replacing: NSRange(location: 3, length: 0), with: "4"))
        XCTAssertFalse(field.accepts("1234", replacing: NSRange(location: 4, length: 0), with: "5"))
        XCTAssertTrue(field.accepts("1234", replacing: NSRange(location: 0, length: 2), with: "98"))
        XCTAssertTrue(field.accepts("1234", replacing: NSRange(location: 0, length: 4), with: ""))
        let free = OverlayField("any", area: ViewRect(0, 0, 100, 40)) { _ in }
        XCTAssertTrue(free.accepts("1234", replacing: NSRange(location: 4, length: 0), with: "5"))
    }

    func test_aFieldTakesTheCaretSecrecyAndTabItIsGiven() {
        let point = ViewPoint(12, 3)
        let field = OverlayField("pw", area: ViewRect(0, 0, 100, 40), caret: .at(point), secure: true) { _ in }
        var tabs: [Bool] = []
        field.onTab = { tabs.append($0) }

        field.onTab?(true)

        XCTAssertTrue(field.secure)
        XCTAssertEqual(tabs, [true])
        guard case .at(let kept) = field.caret else { return XCTFail("the caret was not kept") }
        XCTAssertEqual(kept, point)
        let plain = OverlayField("n", area: ViewRect(0, 0, 1, 1)) { _ in }
        guard case .all = plain.caret else { return XCTFail("a field selects all by default") }
    }

    func test_fieldsLeaveByPrefix() {
        let layer = PageOverlay(page: 0, size: ViewSize(200, 300))
        var dropped = 0
        layer.open(OverlayField("forms.a", area: ViewRect(0, 0, 10, 10)) { if $0 == nil { dropped += 1 } })
        layer.open(OverlayField("comment.b", area: ViewRect(0, 0, 10, 10)) { if $0 == nil { dropped += 1 } })

        layer.dropFields(prefix: "forms.")

        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(layer.fields.map(\.id), ["comment.b"])
    }
}
