import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PrintFlowTests.cs: Lazy Print when it takes the file, otherwise the window prints. The
// paginator tests are left out: PagePaginator is WPF's DocumentPaginator, and the Mac prints through PDFKit (see
// LazyPDFMacTests/SystemPrintTests).

@MainActor
final class PrintFlowTests: XCTestCase {
    func test_lazyPrintIsHandedAFileOfTheDocumentAsItStands() async throws {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = true
        await f.vm.open(f.pdf("letter.pdf"))
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "Unsaved edit")
        _ = try tab.commit("Properties")
        var asked: DocumentTab?
        f.vm.systemPrintRequested = { asked = $0 }

        f.vm.print()

        XCTAssertEqual(f.sisters.printed.count, 1)
        let copy = f.sisters.printed[0]
        XCTAssertEqual(copy.lastPathComponent, "letter.pdf")
        let opened = try PdfDocument.open(path: copy.path)
        XCTAssertEqual(DocumentMetadata.read(opened).title, "Unsaved edit")
        XCTAssertNil(asked)
        XCTAssertEqual(f.vm.statusFull, "Sent to Lazy Print.")
    }

    func test_withoutLazyPrintTheWindowIsAskedToPrintItself() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        var asked: DocumentTab?
        f.vm.systemPrintRequested = { asked = $0 }

        f.vm.print()

        XCTAssertTrue(asked === f.vm.activeDocument)
        XCTAssertEqual(f.sisters.printed.count, 1)
    }

    func test_theCopyForLazyPrintKeepsTheNameOfADocumentMadeFromAPicture() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("photo.png", [1, 2, 3]))

        f.vm.print()

        XCTAssertEqual(f.sisters.printed.map(\.lastPathComponent), ["photo.pdf"])
    }

    func test_onTheHomeTabThereIsNothingToPrint() {
        let f = ViewModelFixture(self)

        f.vm.print()

        XCTAssertTrue(f.sisters.printed.isEmpty)
    }

    // Not in the Windows tests: the copy goes to the print folder, and what is a day old goes at the next print.
    func test_aCopyADayOldIsRemovedAtTheNextPrint() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        f.vm.print()
        let first = f.sisters.printed[0].deletingLastPathComponent()
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: first.path)

        f.vm.print()

        let second = f.sisters.printed[1].deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(second.path.hasPrefix(f.folders.printCopies.path))
    }

    func test_aCopyThatCannotBeWrittenIsReported() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        try Data().write(to: f.folders.printCopies)

        f.vm.print()

        XCTAssertEqual(f.vm.message?.title, "Not printed")
        XCTAssertTrue(f.sisters.printed.isEmpty)
    }
}
