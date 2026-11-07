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

    func test_theOutlineIsATreeInTheFilesOrder() throws {
        let (model, _, _) = try attached(PanelPdfs.full())

        XCTAssertEqual(model.nodes.map { $0.title }, ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(model.nodes[0].children.map { $0.title }, ["Section 1.1"])
        XCTAssertEqual(model.nodes[0].id, "0")
        XCTAssertEqual(model.nodes[0].children[0].id, "0.0")
        XCTAssertTrue(model.nodes[0].italic)
        XCTAssertTrue(model.nodes[0].bold)
        XCTAssertFalse(model.nodes[1].bold)
    }

    func test_aFileWithoutBookmarksHasNoNodes() throws {
        let (model, _, _) = try attached(Pdfs.text())

        XCTAssertTrue(model.nodes.isEmpty)
    }

    func test_choosingAnEntryGoesToItsDestination() throws {
        let (model, viewer, _) = try attached(PanelPdfs.full())

        model.go(model.nodes[1])

        XCTAssertEqual(viewer.sent, [1])
    }

    func test_whichEntriesAreOpenFollowsTheFileUntilThePersonChangesIt() throws {
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
        let tab = try PanelPdfs.tab(bytes)
        let model = AttachmentsModel(openedFolder: dir.sub("opened"))
        model.attach(tab, PanelViewer(tab), RecordingHost())
        return model
    }

    func test_theListHasEachFileWithItsSizeAndNote() throws {
        let model = try attached(TempDir(self))

        XCTAssertEqual(model.rows.map { $0.name }, ["note.txt", "run.exe"])
        XCTAssertEqual(model.rows[0].details, "5 bytes · A note")
        XCTAssertEqual(model.rows[0].summary, "note.txt, 5 bytes · A note")
        XCTAssertEqual(model.rows[1].summary, "run.exe, 2 bytes")
    }

    func test_aFileWithoutAttachmentsHasNoRows() throws {
        let model = try attached(TempDir(self), Pdfs.text())

        XCTAssertTrue(model.rows.isEmpty)
    }

    func test_openingWritesACopyUnderASafeNameAndHandsItOver() throws {
        let dir = TempDir(self)
        let model = try attached(dir)
        var handed: URL?
        model.launch = { handed = $0; return true }
        model.selected = 0

        model.open()

        let url = try XCTUnwrap(handed)
        XCTAssertEqual(url.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
        XCTAssertNil(model.note)
    }

    func test_aFileThatCouldRunIsNotOpenedButCanBeSaved() throws {
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

    func test_whenNothingCanOpenTheCopyTheNoteSaysSo() throws {
        let model = try attached(TempDir(self))
        model.launch = { _ in false }
        model.selected = 0

        model.open()

        XCTAssertEqual(model.note, "This attachment could not be opened.")
    }

    func test_aFailedSaveIsReportedAndASuccessfulOneClearsTheNote() throws {
        let model = try attached(TempDir(self))
        model.selected = 0

        model.saved(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(model.note, "The attachment could not be saved. Check the folder and try again.")
        model.saved(.success(URL(fileURLWithPath: "/tmp/note.txt")))
        XCTAssertNil(model.note)
    }

    func test_theCopiesMadeToOpenFilesCanBeRemoved() throws {
        let dir = TempDir(self)
        let model = try attached(dir)
        model.launch = { _ in true }
        model.selected = 0
        model.open()
        let folder = dir.sub("opened")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        AttachmentsModel.deleteOpenedCopies(in: folder)

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
