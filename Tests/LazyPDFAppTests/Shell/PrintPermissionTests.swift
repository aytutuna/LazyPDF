import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PrintPermissionTests.cs, and adds the print copy and the hand-off. The test of the
// paginator that counts pages the renderer cannot draw belongs to the print dialog of the platform shell.

private extension Pdfs {
    /// A file whose owner password is "owner" and that allows only `allowed` to anyone else.
    static func restricted(_ allowed: PdfPermissions) -> [UInt8] {
        let document = try! PdfDocument.open(text())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: allowed, strength: .aes256, firstId: [])
        return try! document.saveRewrite(PdfSaveOptions(security: security))
    }
}

@MainActor
final class PrintPermissionTests: XCTestCase {
    func test_aFileThatForbidsPrintingIsNotPrinted() async {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = true
        await f.vm.open(f.dir.file("nope.pdf", Pdfs.restricted(PdfPermissions.all.subtracting(.print))))
        var asked: DocumentTab?
        f.vm.systemPrintRequested = { asked = $0 }

        f.vm.print()

        XCTAssertTrue(f.sisters.printed.isEmpty)
        XCTAssertNil(asked)
        XCTAssertEqual(f.vm.message?.title, "Printing is not allowed")
    }

    func test_aFileThatAllowsPrintingIsPrinted() async {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = true
        await f.vm.open(f.dir.file("ok.pdf", Pdfs.restricted(PdfPermissions.all.subtracting(.copy))))

        f.vm.print()

        XCTAssertEqual(f.sisters.printed.count, 1)
        XCTAssertEqual(f.vm.statusFull, "Sent to Lazy Print.")
    }

    func test_theCopyKeepsTheNameOfTheDocument() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("report.pdf"))

        f.vm.print()

        let file = f.sisters.printed[0]
        XCTAssertEqual(file.lastPathComponent, "report.pdf")
        XCTAssertTrue(file.path.hasPrefix(f.folders.printCopies.path))
        XCTAssertFalse(try Data(contentsOf: file).isEmpty)
    }

    func test_theWindowPrintsWhenLazyPrintIsNotThere() async {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = false
        await f.vm.open(f.pdf("a.pdf"))
        var asked: DocumentTab?
        f.vm.systemPrintRequested = { asked = $0 }

        f.vm.print()

        XCTAssertTrue(asked === f.vm.activeDocument)
    }

    func test_nothingIsPrintedFromHome() {
        let f = ViewModelFixture(self)
        var asked = false
        f.vm.systemPrintRequested = { _ in asked = true }

        f.vm.print()

        XCTAssertTrue(f.sisters.printed.isEmpty)
        XCTAssertFalse(asked)
    }

    func test_aCopyAMonthOldGoesAtTheNextPrint() async throws {
        let f = ViewModelFixture(self)
        let old = f.folders.printCopies.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-86400 * 30)], ofItemAtPath: old.path)
        await f.vm.open(f.pdf("a.pdf"))

        f.vm.print()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(f.sisters.printed.count, 1)
    }
}
