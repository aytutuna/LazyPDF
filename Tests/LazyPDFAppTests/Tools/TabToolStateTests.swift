import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// What a tool keeps for a tab belongs to a store the windows share, so a tab that moves to another window finds its marks,
// lists and scales there (the static tables of the Windows tools).

@MainActor
final class TabToolStateTests: XCTestCase {
    func test_redactionMarksFollowTheTabToAnotherModel() async throws {
        let state = TabToolState()
        let rig = try SecurityRig(Pdfs.text(2, "Write to ann@example.com today."))
        let here = RedactModel(fonts: FakeFonts(), images: FakeCodec(), state: state)
        rig.attach(here)
        here.query = "example"
        await here.markWords()
        here.detach()

        let there = RedactModel(fonts: FakeFonts(), images: FakeCodec(), state: state)
        rig.attach(there)

        XCTAssertEqual(there.marks.count, 2)
        XCTAssertEqual(rig.tab.pendingMarks, 2)
    }

    func test_modelsWithTheirOwnStoresShareNothing() async throws {
        let rig = try SecurityRig(Pdfs.text(2, "Write to ann@example.com today."))
        let here = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.attach(here)
        here.query = "example"
        await here.markWords()
        here.detach()

        let there = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.attach(there)

        XCTAssertTrue(there.marks.isEmpty)
    }

    func test_theFilesPickedForCombineFollowTheTab() async throws {
        let state = TabToolState()
        let dir = TempDir(self)
        let rig = try PagesRig(Pdfs.text(3))
        let here = CombineModel(state: state)
        here.attach(rig.tab, rig.viewer, rig.host)
        rig.pick(dir, "b.pdf", Pdfs.text(2, "b"))
        await here.addFiles()
        here.detach()

        let there = CombineModel(state: state)
        there.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertEqual(there.entries.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertTrue(there.action!.canRun())
    }

    func test_aFilePickedAfterTheMoveGoesIntoTheTabsList() async throws {
        let state = TabToolState()
        let dir = TempDir(self)
        let rig = try PagesRig(Pdfs.text(3))
        let here = CombineModel(state: state)
        here.attach(rig.tab, rig.viewer, rig.host)
        here.detach()
        let there = CombineModel(state: state)
        there.attach(rig.tab, rig.viewer, rig.host)

        rig.pick(dir, "c.pdf", Pdfs.text(1, "c"))
        await there.addFiles()

        XCTAssertEqual(there.entries.map(\.name), ["a.pdf", "c.pdf"])
        XCTAssertTrue(there.action!.canRun())
    }

    func test_measurementsAndTheScaleFollowTheTab() async throws {
        let state = TabToolState()
        let rig = try ToolRig()
        let here = MeasureModel(fonts: FakeFonts(), state: state)
        rig.attach(here)
        let tool = try XCTUnwrap(here.tool)
        tool.press(PagePointer(page: 0, point: ViewPoint(0, 0), view: ViewPoint(0, 0), pressed: true, clicks: 1))
        tool.press(PagePointer(page: 0, point: ViewPoint(72, 0), view: ViewPoint(72, 0), pressed: true, clicks: 1))
        here.setPageValue("2")
        here.detach()

        let there = MeasureModel(fonts: FakeFonts(), state: state)
        rig.attach(there)

        XCTAssertEqual(there.rows.count, 1)
        XCTAssertEqual(there.pageValue, "2")
        XCTAssertEqual(rig.tab.pendingMeasurements, 1)
    }

    func test_aClosedTabsEntriesGo() async throws {
        let state = TabToolState()
        let first = try PagesRig(Pdfs.text(2))
        let second = try PagesRig(Pdfs.text(2), title: "c.pdf")
        let model = CombineModel(state: state)
        model.attach(first.tab, first.viewer, first.host)
        model.detach()
        model.attach(second.tab, second.viewer, second.host)
        XCTAssertEqual(state.combine.count, 2)

        first.tab.dispose()
        model.detach()

        XCTAssertEqual(state.combine.count, 1)
    }

    func test_aTabThatIsReleasedAndAdoptedKeepsItsEntries() async throws {
        let f = ViewModelFixture(self)
        let registry = DocumentRegistry()
        let state = TabToolState()
        let a = f.makeViewModel(registry: registry, toolState: state)
        let b = f.makeViewModel(registry: registry, toolState: state)
        await a.open(f.pdf())
        let tab = try XCTUnwrap(a.activeDocument)
        state.combine[tab] = [CombineEntry("a.pdf", 1, nil)]

        XCTAssertTrue(registry.transfer(tab, from: a, to: b, at: 1))

        XCTAssertEqual(b.toolState.combine[tab]?.count, 1)
        b.close(tab)
        state.combine.prune()
        XCTAssertEqual(state.combine.count, 0)
    }
}
