import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/EditSessionTests.cs: the same cases. The assertions the C# makes
// with PdfPig (CurrentIsAlwaysACompleteFileAndNeverChangesInPlace, SaveCompactDropsTheHistory) are made with the
// engine's own reader instead; the rest of those two tests is unchanged.

final class EditSessionTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = try temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func path(_ name: String) -> String {
        folder.appendingPathComponent(name).path
    }

    private func write(_ bytes: [UInt8], _ name: String) throws -> String {
        let full = path(name)
        try Data(bytes).write(to: URL(fileURLWithPath: full))
        return full
    }

    private func read(_ full: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: full)))
    }

    private func retitle(_ session: PdfEditSession, _ title: String) {
        session.document.info?["Title"] = PdfString(bytes: Latin1.bytes(title), isHex: false)
    }

    private func title(_ session: PdfEditSession) -> String {
        SaveFixtures.title(session.document)
    }

    func test_fileThatIsNotAPdfIsRefused() {
        assertReadFails(try PdfEditSession.open(Array("not a pdf".utf8)), .notPdf)
    }

    func test_commitAppendsAnUpdateAndUndoRedoMoveTheEnd() throws {
        let original = SaveFixtures.table()
        let session = try PdfEditSession.open(original)
        XCTAssertEqual(session.current, original)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)

        retitle(session, "One")
        XCTAssertTrue(try session.commit("Title one"))
        let afterOne = session.current
        retitle(session, "Two")
        XCTAssertTrue(try session.commit("Title two"))
        let afterTwo = session.current

        XCTAssertEqual(Array(afterOne[0..<original.count]), original)
        XCTAssertEqual(Array(afterTwo[0..<afterOne.count]), afterOne)
        XCTAssertEqual(title(session), "Two")
        XCTAssertEqual(session.undoLabel, "Title two")

        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.current, afterOne)
        XCTAssertEqual(title(session), "One")
        XCTAssertEqual(session.undoLabel, "Title one")
        XCTAssertEqual(session.redoLabel, "Title two")
        XCTAssertTrue(session.canRedo)

        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.current, original)
        XCTAssertEqual(title(session), "Original title")
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(try session.undo())

        XCTAssertTrue(try session.redo())
        XCTAssertTrue(try session.redo())
        XCTAssertEqual(session.current, afterTwo)
        XCTAssertEqual(title(session), "Two")
        XCTAssertFalse(try session.redo())
        XCTAssertNil(session.redoLabel)
    }

    func test_commitWithNothingChangedAddsNothing() throws {
        let session = try PdfEditSession.open(SaveFixtures.table())
        let before = session.current
        XCTAssertFalse(try session.commit("Nothing"))
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.current, before)
        _ = session.document.pages[0].contents()
        XCTAssertFalse(try session.commit("Still nothing"))
    }

    func test_commitAfterUndoDropsWhatCouldBeRedone() throws {
        let session = try PdfEditSession.open(SaveFixtures.table())
        retitle(session, "A")
        try session.commit("A")
        retitle(session, "B")
        try session.commit("B")
        try session.undo()
        retitle(session, "C")
        try session.commit("C")
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(title(session), "C")
        try session.undo()
        XCTAssertEqual(title(session), "A")
        try session.undo()
        XCTAssertEqual(title(session), "Original title")
    }

    func test_undoDropsChangesNotYetCommitted() throws {
        let session = try PdfEditSession.open(SaveFixtures.table())
        retitle(session, "A")
        try session.commit("A")
        retitle(session, "Pending")
        XCTAssertTrue(session.document.hasChanges)
        try session.undo()
        XCTAssertFalse(session.document.hasChanges)
        XCTAssertEqual(title(session), "Original title")
    }

    func test_currentIsAlwaysACompleteFileAndNeverChangesInPlace() throws {
        let session = try PdfEditSession.open(SaveFixtures.table())
        let first = session.current
        retitle(session, "A")
        try session.commit("A")
        XCTAssertEqual(SaveFixtures.table(), first)
        let reopened = try PdfDocument.open(session.current)
        XCTAssertEqual(SaveFixtures.title(reopened), "A")
        XCTAssertTrue(reopened.repairs.isEmpty)
    }

    func test_manyCommitsStayReadable() throws {
        let session = try PdfEditSession.open(SaveFixtures.table())
        for i in 0..<60 {
            retitle(session, "Title \(i)")
            session.document.pages[i % 2].dictionary["Rotate"] = PdfNumber(i % 4 * 90)
            XCTAssertTrue(try session.commit("Edit \(i)"))
        }
        let final = try PdfDocument.open(session.current)
        XCTAssertEqual(SaveFixtures.title(final), "Title 59")
        XCTAssertEqual(PdfVersion.find(final).count, 61)
        for _ in 0..<60 { XCTAssertTrue(try session.undo()) }
        XCTAssertEqual(title(session), "Original title")
    }

    func test_isDirtyIsAgainstTheLastSave() throws {
        let file = try write(SaveFixtures.table(), "a.pdf")
        let session = try PdfEditSession.open(path: file)
        XCTAssertFalse(session.isDirty)

        retitle(session, "A")
        XCTAssertTrue(session.isDirty)
        try session.commit("A")
        XCTAssertTrue(session.isDirty)

        try session.save(file)
        XCTAssertFalse(session.isDirty)
        retitle(session, "B")
        try session.commit("B")
        XCTAssertTrue(session.isDirty)
        try session.undo()
        XCTAssertFalse(session.isDirty)
        try session.undo()
        XCTAssertTrue(session.isDirty)
        try session.redo()
        XCTAssertFalse(session.isDirty)

        // A new step made after going back past the save loses that state for good.
        try session.undo()
        retitle(session, "C")
        try session.commit("C")
        try session.undo()
        try session.redo()
        XCTAssertTrue(session.isDirty)
    }

    func test_saveWritesTheBufferAndCommitsWhatWaits() throws {
        let file = try write(SaveFixtures.table(), "b.pdf")
        let session = try PdfEditSession.open(path: file)
        retitle(session, "Waiting")
        try session.save(file)

        let saved = try read(file)
        XCTAssertEqual(session.current, saved)
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(saved)), "Waiting")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["b.pdf"])
        XCTAssertTrue(session.canUndo)
    }

    func test_saveCompactDropsTheHistory() throws {
        let file = path("c.pdf")
        let session = try PdfEditSession.open(SaveFixtures.table())
        for i in 0..<10 {
            retitle(session, "Version \(i)")
            try session.commit("Edit \(i)")
        }
        let before = session.current.count
        try session.saveCompact(file)

        XCTAssertLessThan(try read(file).count, before)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(title(session), "Version 9")
        XCTAssertEqual(session.versions.count, 1)
        retitle(session, "After")
        try session.commit("After")
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(title(session), "Version 9")
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(path: file)), "Version 9")
    }

    func test_saveCompactKeepsEncryption() throws {
        let file = path("d.pdf")
        let session = try PdfEditSession.open(SaveFixtures.make("aes256"))
        retitle(session, "Locked")
        try session.commit("Locked")
        try session.saveCompact(file)
        XCTAssertTrue(try PdfDocument.open(path: file).isEncrypted)
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(path: file)), "Locked")
    }

    func test_encryptedFileWithAPasswordIsEditedAndSaved() throws {
        let security = PdfSecurity.create(userPassword: "secret", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: SaveFixtures.fileId)
        let bytes = try PdfDocument.open(SaveFixtures.table()).saveRewrite(PdfSaveOptions(security: security))
        assertReadFails(try PdfEditSession.open(bytes))

        let file = path("e.pdf")
        let session = try PdfEditSession.open(bytes, password: "secret")
        retitle(session, "Edited")
        try session.commit("Edit")
        try session.undo()
        try session.redo()
        try session.save(file)
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(path: file, password: "secret")), "Edited")
    }

    func test_versionsListTheFilesOwnRevisionsAndCanBeExtracted() throws {
        let v1 = SaveFixtures.table()
        var document = try PdfDocument.open(v1)
        document.info?["Title"] = PdfString(bytes: [50], isHex: false)
        let v2 = try document.saveIncremental()
        document = try PdfDocument.open(v2)
        document.info?["Title"] = PdfString(bytes: [51], isHex: false)
        let v3 = try document.saveIncremental()

        let session = try PdfEditSession.open(v3)
        XCTAssertEqual(session.versions.map { $0.end }, [v1.count, v2.count, v3.count])
        XCTAssertEqual(session.versions.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(session.extractVersion(session.versions[0]), v1)
        XCTAssertEqual(session.extractVersion(session.versions[1]), v2)

        let file = path("v.pdf")
        try session.saveVersion(session.versions[1], file)
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(path: file)), "2")
        retitle(session, "New")
        try session.commit("New")
        XCTAssertEqual(session.versions.count, 3)
        XCTAssertEqual(session.extractVersion(session.versions[0]), v1)
    }

    func test_versionsOfOtherLayouts() throws {
        for kind in ["stream", "hybrid", "aes128"] {
            let document = try PdfDocument.open(SaveFixtures.make(kind))
            document.info?["Title"] = PdfString(bytes: [50], isHex: false)
            let session = try PdfEditSession.open(document.saveIncremental())
            XCTAssertEqual(session.versions.count, 2, kind)
            let file = path("x.pdf")
            try session.saveVersion(session.versions[0], file)
            XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(path: file)), "Original title", kind)
        }
    }

    func test_rebuiltFileHasNoVersionsButCanStillBeEdited() throws {
        let session = try PdfEditSession.open(TestPdf.replace(SaveFixtures.table(), "startxref", "startxxxxx"))
        XCTAssertTrue(session.versions.isEmpty)
        retitle(session, "Fixed")
        XCTAssertTrue(try session.commit("Fix"))
        XCTAssertTrue(try PdfDocument.open(session.current).repairs.isEmpty)
        XCTAssertEqual(try PdfEditSession.open(session.current).versions.count, 1)
    }

    func test_versionIsNotMadeOfAStartxrefInsideStreamData() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>")
        pdf.stream(4, "", "startxref\n9\n%%EOF\n")
        let session = try PdfEditSession.open(pdf.finish())
        XCTAssertEqual(session.versions.count, 1)
    }
}
