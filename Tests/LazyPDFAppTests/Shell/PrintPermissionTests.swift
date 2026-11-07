import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PrintPermissionTests.cs. The last test there counts the pages the WPF paginator
// printed blank; the Mac has no paginator, so it is left out.

@MainActor
final class PrintPermissionTests: XCTestCase {
    /// A file whose owner password is "owner" and that allows only `allowed` to anyone else.
    private func restricted(_ allowed: PdfPermissions) throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: allowed, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }

    func test_aFileThatForbidsPrintingIsNotPrinted() async throws {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = true
        await f.vm.open(f.dir.file("nope.pdf", try restricted(PdfPermissions.all.subtracting(.print))))
        var asked: DocumentTab?
        f.vm.systemPrintRequested = { asked = $0 }

        f.vm.print()

        XCTAssertTrue(f.sisters.printed.isEmpty)
        XCTAssertNil(asked)
        XCTAssertEqual(f.vm.message?.title, "Printing is not allowed")
    }

    func test_aFileThatAllowsPrintingIsPrinted() async throws {
        let f = ViewModelFixture(self)
        f.sisters.printTaken = true
        await f.vm.open(f.dir.file("ok.pdf", try restricted(PdfPermissions.all.subtracting(.copy))))

        f.vm.print()

        XCTAssertEqual(f.sisters.printed.count, 1)
    }
}
