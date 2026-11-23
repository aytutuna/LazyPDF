import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/pages/PageGateTests.cs: a restricted file refuses the page edits of the organize view and
// the Pages inspector, a signed one asks first and goes on from the notice.

@MainActor
final class PageGateTests: XCTestCase {
    private typealias Edit = (name: String, run: (OrganizeModel, TempDir) async -> Void)

    private let edits: [Edit] = [
        ("turn", { model, _ in model.turn([1], 90) }),
        ("remove", { model, _ in model.grid.select([1]); model.remove() }),
        ("duplicate", { model, _ in model.grid.select([1]); await model.duplicate() }),
        ("cut", { model, _ in model.grid.select([1]); await model.cut() }),
        ("nudge", { model, _ in model.grid.later([1]) }),
        ("move", { model, _ in model.grid.moveTo([3], 1) }),
        ("blank", { model, _ in model.grid.select([1]); model.blank() }),
        ("paste", { model, _ in
            PageClipboard.shared.set(Pdfs.text(1, "Pasted"), 1)
            model.grid.select([1])
            await model.paste()
        }),
        ("files", { model, dir in
            await model.insertFiles([ToolFile(url: dir.file("more.pdf", Pdfs.text(1, "More")))], at: 1)
        }),
    ]

    private func attached(_ bytes: [UInt8]) throws -> (model: OrganizeModel, rig: PagesRig) {
        let rig = try PagesRig(bytes)
        let model = OrganizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        return (model, rig)
    }

    func test_aRestrictedFileRefusesEveryEdit() async throws {
        for edit in edits {
            let dir = TempDir(self)
            let (model, rig) = try attached(Pdfs.restricted(.print, pages: 4))
            let revision = rig.tab.revision

            await edit.run(model, dir)

            XCTAssertEqual(rig.host.problems.map(\.title), ["This file cannot be changed"], edit.name)
            XCTAssertTrue(rig.host.notices.isEmpty, edit.name)
            XCTAssertEqual(rig.tab.revision, revision, edit.name)
        }
    }

    func test_aSignedFileAsksFirstAndGoesOnFromTheNotice() async throws {
        for edit in edits {
            let dir = TempDir(self)
            let (model, rig) = try attached(Pdfs.signed(certified: false, pages: 4))
            let revision = rig.tab.revision

            await edit.run(model, dir)

            XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"], edit.name)
            XCTAssertEqual(rig.tab.revision, revision, edit.name)
            XCTAssertTrue(rig.host.problems.isEmpty, edit.name)

            rig.host.notices[0].action?.run()
            await waitUntil { rig.tab.revision != revision }

            XCTAssertEqual(rig.host.notices.count, 1, edit.name)
            XCTAssertTrue(rig.host.problems.isEmpty, edit.name)
            XCTAssertTrue(try rig.tab.undo(), edit.name)
            XCTAssertFalse(rig.tab.session.canUndo, edit.name)
        }
    }

    func test_theInspectorGatesItsEditsToo() async throws {
        let restricted = try PagesRig(Pdfs.restricted(.print, pages: 4))
        let panel = PagesToolModel()
        panel.attach(restricted.tab, restricted.viewer, restricted.host)
        panel.grid.select([1])

        panel.turn(90)
        panel.removeLabels()
        panel.remove()

        XCTAssertEqual(restricted.host.problems.count, 3)
        XCTAssertFalse(restricted.tab.session.canUndo)

        let signed = try PagesRig(Pdfs.signed(certified: true, pages: 4))
        let other = PagesToolModel()
        other.attach(signed.tab, signed.viewer, signed.host)
        other.grid.select([1])
        other.turn(90)

        XCTAssertEqual(signed.host.notices.map(\.title), ["Check before going on"])
        XCTAssertEqual(signed.host.notices[0].text, "This file is certified, so changing it makes viewers report it as altered.")
        XCTAssertFalse(signed.tab.session.canUndo)
        signed.host.notices[0].action?.run()
        XCTAssertTrue(signed.tab.session.canUndo)
    }

    func test_goOnAnywayDoesNothingWhenTheDocumentChangedMeanwhile() async throws {
        let (model, rig) = try attached(Pdfs.signed(certified: false, pages: 4))
        model.grid.select([1])
        model.remove()
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        rig.tab.refresh()
        let revision = rig.tab.revision

        rig.host.notices[0].action?.run()

        XCTAssertEqual(rig.tab.revision, revision)
        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Pages not changed"])
    }

    func test_theCropBoxGoesWhenTheCropStartsAfterGoOnAnyway() async throws {
        let rig = try PagesRig(Pdfs.signed(certified: false, pages: 3))
        let model = PagesToolModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.setExpanded(.crop, true)
        let tool = try XCTUnwrap(model.crop)
        tool.press(PagePointer(page: 0, point: ViewPoint(50, 60), view: .zero, pressed: true, clicks: 1))
        tool.release(PagePointer(page: 0, point: ViewPoint(150, 160), view: .zero, pressed: false, clicks: 0))

        await model.action!.run()
        XCTAssertNotNil(model.cropBox)
        rig.host.notices[0].action?.run()

        XCTAssertNil(model.cropBox)
        XCTAssertTrue(rig.tab.session.canUndo)
    }
}
