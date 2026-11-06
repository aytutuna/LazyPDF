import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DiskNoticeTests.cs: the file under an open tab is looked at when its tab comes forward,
// and each new state of it is told once.

@MainActor
final class DiskNoticeTests: XCTestCase {
    func test_aChangeAfterADismissedNoticeIsToldAgain() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try touch(url, Pdfs.text(2), minutes: 10)
        f.vm.checkDisk()
        f.vm.dismissMessage()

        try touch(url, Pdfs.text(3), minutes: 20)
        f.vm.checkDisk()

        XCTAssertEqual(f.vm.message?.title, "File changed")
        XCTAssertNotNil(f.vm.message?.action)
    }

    func test_aFileDeletedAfterAChangeNoticeIsToldToo() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try touch(url, Pdfs.text(2), minutes: 10)
        f.vm.checkDisk()
        f.vm.dismissMessage()

        try FileManager.default.removeItem(at: url)
        f.vm.checkDisk()

        XCTAssertEqual(f.vm.message?.title, "File is gone")
    }

    func test_comingToATabLooksAtItsFile() async throws {
        let f = ViewModelFixture(self)
        let a = f.pdf("a.pdf")
        await f.vm.open([a, f.pdf("b.pdf")])
        try touch(a, Pdfs.text(2), minutes: 10)
        f.vm.dismissMessage()

        f.vm.select(f.vm.documents.first!)

        XCTAssertEqual(f.vm.message?.title, "File changed")
    }

    func test_openingTheNewVersionClearsWhatWasToldAboutTheOldOne() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try touch(url, Pdfs.text(2), minutes: 10)
        f.vm.checkDisk()
        await f.vm.reload(f.vm.activeDocument!)
        f.vm.dismissMessage()

        f.vm.checkDisk()
        XCTAssertNil(f.vm.message)

        try touch(url, Pdfs.text(3), minutes: 20)
        f.vm.checkDisk()
        XCTAssertEqual(f.vm.message?.title, "File changed")
    }
}
