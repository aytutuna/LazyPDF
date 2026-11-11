import XCTest
import Observation
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DiskChangeTests.cs: a file changed under the app's hands is noticed once, and the new
// version can be opened in its place.

@MainActor
final class DiskChangeTests: XCTestCase {
    func test_anUnchangedFileSaysNothing() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())

        f.vm.checkDisk()

        XCTAssertNil(f.vm.message)
    }

    func test_aChangedFileIsToldOnceWithAWayToOpenTheNewVersion() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try touch(url, Pdfs.text(3))

        f.vm.checkDisk()

        XCTAssertEqual(f.vm.message?.title, "File changed")
        XCTAssertTrue(f.vm.message?.text.contains("a.pdf") == true)
        XCTAssertNotNil(f.vm.message?.action)
        f.vm.dismissMessage()
        f.vm.checkDisk()
        XCTAssertNil(f.vm.message)
    }

    func test_aFileOnlyTouchedSaysNothingAndSaves() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try touch(url, [UInt8](try Data(contentsOf: url)))
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")

        f.vm.checkDisk()
        XCTAssertNil(f.vm.message)
        XCTAssertTrue(f.vm.save(tab))

        XCTAssertNil(f.vm.message)
        XCTAssertFalse(tab.isDirty)
    }

    func test_aRewriteOfTheSameLengthStillSaysChanged() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[bytes.count - 1] ^= 1
        try touch(url, bytes)

        f.vm.checkDisk()

        XCTAssertEqual(f.vm.message?.title, "File changed")
    }

    func test_withUnsavedChangesTheNoticeSaysTheyWouldBeLost() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")
        try touch(url, Pdfs.text(3))

        f.vm.checkDisk()

        XCTAssertTrue(f.vm.message?.text.contains("drops your unsaved changes") == true)
    }

    func test_aDeletedFileSaysToSaveAgain() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try FileManager.default.removeItem(at: url)

        f.vm.checkDisk()

        XCTAssertEqual(f.vm.message?.title, "File is gone")
        XCTAssertNil(f.vm.message?.action)
    }

    func test_openingTheNewVersionReplacesTheTabInTheSamePlace() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("a.pdf")
        await f.vm.open([url, f.pdf("b.pdf")])
        let old = f.vm.documents.first!
        try touch(url, Pdfs.text(3))

        await f.vm.reload(old)

        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf", "b.pdf"])
        XCTAssertEqual(f.vm.documents.first?.pageCount, 3)
        XCTAssertFalse(f.vm.documents.first === old)
    }

    func test_reloadingTheActiveTabTellsTheWindowAboutTheNewOne() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let old = f.vm.activeDocument!
        try touch(url, Pdfs.text(3))
        let announced = Counter()
        withObservationTracking({ _ = f.vm.activeTab }, onChange: { announced.count += 1 })

        await f.vm.reload(old)

        XCTAssertFalse(f.vm.activeDocument === old)
        XCTAssertNotNil(f.vm.activeDocument)
        XCTAssertEqual(announced.count, 1)
    }

    func test_theButtonOfANoticeGoesWhenTheTabIsClosed() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try touch(url, Pdfs.text(3))
        f.vm.checkDisk()
        XCTAssertNotNil(f.vm.message?.action)

        f.vm.close(tab)

        XCTAssertNil(f.vm.message)
    }

    func test_ourOwnSaveIsNotReportedAsAChange() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")
        f.vm.save(tab)
        f.vm.dismissMessage()

        f.vm.checkDisk()

        XCTAssertNil(f.vm.message)
    }

    func test_onTheHomeTabThereIsNothingToCheck() {
        let f = ViewModelFixture(self)

        f.vm.checkDisk()

        XCTAssertNil(f.vm.message)
    }
}
