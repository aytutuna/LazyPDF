import XCTest
@testable import LazyPDFKit

// DocumentExposesTheFact of windows/LazyPDF.Core.Tests/Crypt/PublicKeyPermsTests.cs, which opens a PdfDocument and so
// was left out of the Crypt layer's twin (Crypt/PublicKeyPermsTests.swift): the same case.

final class PermsDocumentTests: XCTestCase {
    func test_documentExposesTheFact() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "o", permissions: .print, strength: .aes256, firstId: id)
        let file = try PdfDocument.open(SealedPage.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: id))
        let untouched = try PdfDocument.open(file)

        // Same length, so the offsets stay right: the last digit of /P is the only change.
        let start = try XCTUnwrap(file.indexOf(TestPdf.latin("/P -")))
        var end = start + 4
        while end < file.count && file[end] >= 0x30 && file[end] <= 0x39 { end += 1 }
        var edited = file
        let last = file[end - 1]
        edited[end - 1] = last == UInt8(ascii: "9") ? UInt8(ascii: "8") : last + 1
        let tampered = try PdfDocument.open(edited)

        XCTAssertEqual(untouched.security?.permsMismatch, false)
        XCTAssertEqual(tampered.security?.permsMismatch, true)
        XCTAssertTrue(tampered.repairs.isEmpty)
    }
}
