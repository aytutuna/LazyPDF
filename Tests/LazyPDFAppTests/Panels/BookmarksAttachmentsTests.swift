import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Bookmarks and Attachments panels. Windows tests neither panel; AttachmentFilesTests (the safe names) are in
// SmallServicesTests.

@MainActor
final class BookmarksModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]) throws -> (model: BookmarksModel, viewer: PanelViewer, tab: DocumentTab) {
        let tab = try PanelPdfs.tab(bytes)
        let viewer = PanelViewer(tab)
        let model = BookmarksModel()
        model.attach(tab, viewer, RecordingHost())
        return (model, viewer, tab)
    }

    func test_theOutlineIsATreeInTheFilesOrder() async throws {
        let (model, _, _) = try attached(PanelPdfs.full())

        XCTAssertEqual(model.nodes.map { $0.title }, ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(model.nodes[0].children.map { $0.title }, ["Section 1.1"])
        XCTAssertEqual(model.nodes[0].id, "0")
        XCTAssertEqual(model.nodes[0].children[0].id, "0.0")
        XCTAssertTrue(model.nodes[0].italic)
        XCTAssertTrue(model.nodes[0].bold)
        XCTAssertFalse(model.nodes[1].bold)
    }

    func test_aFileWithoutBookmarksHasNoNodes() async throws {
        let (model, _, _) = try attached(Pdfs.text())

        XCTAssertTrue(model.nodes.isEmpty)
    }

    func test_choosingAnEntryGoesToItsDestination() async throws {
        let (model, viewer, _) = try attached(PanelPdfs.full())

        model.go(model.nodes[1])

        XCTAssertEqual(viewer.sent, [1])
    }

    func test_anEntryThatGoesNowhereSaysSo() async throws {
        let tab = try PanelPdfs.tab(PanelPdfs.full())
        let viewer = PanelViewer(tab)
        let host = RecordingHost()
        let model = BookmarksModel()
        model.attach(tab, viewer, host)
        let item = model.nodes[1].item

        item.destination = PdfDestination(99)
        model.go(model.nodes[1])
        XCTAssertEqual(host.statuses, ["This bookmark points to a page that is not in the file."])
        XCTAssertTrue(viewer.sent.isEmpty)

        item.destination = nil
        item.action = JavaScriptAction("app.alert(1)")
        model.go(model.nodes[1])
        XCTAssertEqual(host.statuses.last, "This bookmark does something Lazy PDF cannot do.")
        XCTAssertEqual(host.statuses.count, 2)

        item.action = nil
        model.go(model.nodes[1])
        XCTAssertEqual(host.statuses.count, 2)
        XCTAssertTrue(viewer.followed.isEmpty)
    }

    func test_whichEntriesAreOpenFollowsTheFileUntilThePersonChangesIt() async throws {
        let (model, _, _) = try attached(PanelPdfs.full())
        let chapter = model.nodes[0]

        XCTAssertTrue(model.isExpanded(chapter))
        model.setExpanded(chapter, false)

        XCTAssertFalse(model.isExpanded(chapter))
        XCTAssertFalse(model.isExpanded(model.nodes[1]))
    }

    func test_whatWasOpenedIsKeptWhenTheFileChangesAndForgottenForAnotherDocument() async throws {
        let (model, viewer, tab) = try attached(PanelPdfs.full())
        model.setExpanded(model.nodes[0], false)

        try Pdfs.retitle(tab.session, "New title")
        try tab.commit("Properties")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isExpanded(model.nodes[0]))

        model.detach()
        let other = try PanelPdfs.tab(PanelPdfs.full())
        model.attach(other, viewer, RecordingHost())
        XCTAssertTrue(model.isExpanded(model.nodes[0]))
    }
}

@MainActor
final class AttachmentsModelTests: XCTestCase {
    private func attached(_ dir: TempDir, _ bytes: [UInt8] = PanelPdfs.full()) throws -> AttachmentsModel {
        try rig(dir, bytes).model
    }

    private func rig(_ dir: TempDir, _ bytes: [UInt8] = PanelPdfs.full()) throws -> (model: AttachmentsModel, host: RecordingHost, tab: DocumentTab) {
        let tab = try PanelPdfs.tab(bytes)
        let host = RecordingHost()
        let model = AttachmentsModel(openedFolder: dir.sub("opened"))
        model.attach(tab, PanelViewer(tab), host)
        return (model, host, tab)
    }

    func test_theListHasEachFileWithItsSizeAndNote() async throws {
        let model = try attached(TempDir(self))

        XCTAssertEqual(model.rows.map { $0.name }, ["note.txt", "run.exe"])
        XCTAssertEqual(model.rows[0].details, "5 bytes · A note")
        XCTAssertEqual(model.rows[0].summary, "note.txt, 5 bytes · A note")
        XCTAssertEqual(model.rows[1].summary, "run.exe, 2 bytes")
    }

    func test_aFileWithoutAttachmentsHasNoRows() async throws {
        let model = try attached(TempDir(self), Pdfs.text())

        XCTAssertTrue(model.rows.isEmpty)
    }

    func test_openingAsksFirstThenWritesACopyUnderASafeNameAndHandsItOver() async throws {
        let (model, host, _) = try rig(TempDir(self))
        var handed: URL?
        model.launch = { handed = $0; return true }
        model.selected = 0

        model.open()

        XCTAssertNil(handed)
        let notice = try XCTUnwrap(host.notices.first)
        XCTAssertEqual(notice.title, "Open this attachment?")
        notice.action?.run()
        let url = try XCTUnwrap(handed)
        XCTAssertEqual(url.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
        XCTAssertNil(model.note)
    }

    func test_anAnswerAfterTheFileChangedOpensNothing() async throws {
        let (model, host, tab) = try rig(TempDir(self))
        var handed = false
        model.launch = { _ in handed = true; return true }
        model.selected = 0
        model.open()

        tab.refresh()
        try XCTUnwrap(host.notices.first?.action).run()

        XCTAssertFalse(handed)
        XCTAssertEqual(model.note, "The file changed meanwhile. Try again.")
    }

    func test_aFileThatCouldRunIsNotOpenedButCanBeSaved() async throws {
        let dir = TempDir(self)
        let model = try attached(dir)
        var handed = false
        model.launch = { _ in handed = true; return true }
        model.selected = 1

        model.open()

        XCTAssertFalse(handed)
        XCTAssertEqual(model.note, "This file could run as a program. Save it instead.")
        let saved = try XCTUnwrap(model.fileToSave())
        XCTAssertEqual(saved.name, "run.exe")
        XCTAssertEqual(saved.bytes, Array("MZ".utf8))
    }

    func test_whenNothingCanOpenTheCopyTheNoteSaysSo() async throws {
        let (model, host, _) = try rig(TempDir(self))
        model.launch = { _ in false }
        model.selected = 0

        model.open()
        try XCTUnwrap(host.notices.first?.action).run()

        XCTAssertEqual(model.note, "This attachment could not be opened.")
    }

    func test_aFailedSaveIsReportedAndASuccessfulOneClearsTheNote() async throws {
        let model = try attached(TempDir(self))
        model.selected = 0

        model.saved(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(model.note, "The attachment could not be saved. Check the folder and try again.")
        model.saved(.success(URL(fileURLWithPath: "/tmp/note.txt")))
        XCTAssertNil(model.note)
    }

    func test_theCopiesMadeToOpenFilesCanBeRemoved() async throws {
        let dir = TempDir(self)
        let (model, host, _) = try rig(dir)
        model.launch = { _ in true }
        model.selected = 0
        model.open()
        try XCTUnwrap(host.notices.first?.action).run()
        let folder = dir.sub("opened")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        AttachmentsModel.deleteOpenedCopies(in: folder)

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
