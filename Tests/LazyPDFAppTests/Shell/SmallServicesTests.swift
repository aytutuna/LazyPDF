import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/StatusLineTests.cs, AttachmentFilesTests.cs and RestrictedFileTests.cs. The last of
// them also tested the tools' change gate with a WPF host; that part belongs to the piece that ports the tools.

final class StatusLineTests: XCTestCase {
    func test_aShortSentenceIsShownWithoutItsFullStop() {
        XCTAssertEqual(StatusLine.short("Saved a.pdf."), "Saved a.pdf")
    }

    func test_aLongOneIsCutAtItsFirstSentence() {
        XCTAssertEqual(StatusLine.short("Sent to Lazy Print. It opens in a moment."), "Sent to Lazy Print")
    }

    func test_aLongSentenceIsCutAtAColonOrAComma() {
        XCTAssertEqual(StatusLine.short("Not saved: the disk is full and nothing else could be done."), "Not saved")
    }

    func test_withNoPlaceToCutItKeepsSixWords() {
        let text = StatusLine.short("One two three four five six seven eight")

        XCTAssertEqual(text, "One two three four five six\u{2026}")
        XCTAssertEqual(StatusLine.words(text), StatusLine.maxWords)
    }

    func test_nothingGivesNothing() {
        XCTAssertEqual(StatusLine.short("   "), "")
    }

    func test_wordsCountOnlyTokensWithALetterOrDigit() {
        XCTAssertEqual(StatusLine.words("Page 3 \u{B7} done \u{2014}"), 3)
    }
}

final class AttachmentFilesTests: XCTestCase {
    func test_programsAreRecognisedWhateverTheyEndWith() {
        for name in ["invoice.exe", "INVOICE.EXE", "invoice.exe ", "invoice.exe.", "invoice.exe. . ", "help.chm", "link.url",
                     "setup.appref-ms", "..\\..\\tools\\run.bat", "../../tools/run.sh", "Tool.app"] {
            XCTAssertTrue(AttachmentFiles.couldRun(AttachmentFiles.safeName(name)), name)
        }
    }

    func test_otherThingsThatStartOrInstallSomethingAreRecognised() {
        for name in ["setup.tool", "a.mpkg", "a.mobileconfig", "a.fileloc", "a.shortcut", "a.prefPane", "a.osax", "a.kext",
                     "a.dylib", "a.bundle"] {
            XCTAssertTrue(AttachmentFiles.couldRun(AttachmentFiles.safeName(name)), name)
        }
    }

    func test_documentsAreNot() {
        for name in ["report.pdf", "photo.jpg", "notes"] {
            XCTAssertFalse(AttachmentFiles.couldRun(AttachmentFiles.safeName(name)), name)
        }
    }

    func test_theNameIsTheOneTheFileSystemWillWrite() {
        XCTAssertEqual(AttachmentFiles.safeName("a.txt. "), "a.txt")
        XCTAssertEqual(AttachmentFiles.safeName("a*b.txt"), "a_b.txt")
        XCTAssertEqual(AttachmentFiles.safeName("..\\x\\c.txt"), "c.txt")
        XCTAssertEqual(AttachmentFiles.safeName("../x/c.txt"), "c.txt")
    }
}

@MainActor
final class RestrictedFileTests: XCTestCase {
    private struct Denied: Error {}

    func test_aJobThatCoreRefusesShowsThePermissionsMessage() async throws {
        let f = ViewModelFixture(self)

        try await f.vm.runBusy("Working") { _ in throw PdfPermissionException("The file restricts its permissions.") }

        XCTAssertEqual(f.vm.message?.title, Problems.restricted().title)
        XCTAssertEqual(f.vm.message?.text, Problems.restricted().text)
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_aFileSystemRefusalIsLeftToTheTool() async {
        let f = ViewModelFixture(self)

        do {
            try await f.vm.runBusy("Working") { _ in throw Denied() }
            XCTFail("The error should have reached the tool.")
        } catch {
            XCTAssertTrue(error is Denied)
        }

        XCTAssertNil(f.vm.message)
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_theMessageSaysWhatToDo() {
        let problem = Problems.restricted()

        XCTAssertEqual(problem.title, "This file cannot be changed")
        XCTAssertTrue(problem.text.contains("owner password"))
    }
}
