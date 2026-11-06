#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureFreedObjectTests.cs: the same cases.

final class SignatureFreedObjectTests: XCTestCase {
    func test_aPageFreedWhileThePageTreeStillListsItIsNotAllowed() throws {
        let file = try SignatureTestHelpers.certified(.noChanges)
        let page = try PdfDocument.open(file).pages[0].reference.number

        let attacked = try SignatureTestHelpers.edit(file) { d in d.delete(page) }

        let report = try SignatureTestHelpers.first(attacked)
        XCTAssertNotEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .pageStructure })
    }

    func test_aStreamListedAndThenFreedWhileTheSignedPageStillPointsAtItIsNotAllowed() throws {
        let pdf = SignatureSharedRoleTests.doc(page: "/Contents [4 0 R 99 0 R]")
        let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
        let listed = try SignatureTestHelpers.appendRaw(signed, [(99, SignatureRawKit.streamBody(SignatureRawKit.evil))])
        XCTAssertEqual(try SignatureKit.verify(listed)[0].verdict, .changedAfterSigning)

        let freed = try SignatureForgeryTests.appendSection(listed, "", "99 1\n0000000000 00001 f \n")

        let report = try SignatureKit.verify(freed)[0]
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.object == 99 })
    }
}
#endif
