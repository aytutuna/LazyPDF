#if os(macOS)
import XCTest
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit

// Mirrors windows/LazyPDF.App.Tests/WindowsCertificatesTests.cs and the opening of a file for recipients from
// CertificateReadersTests.cs. The identities are .p12 files made here and read through the engine; the keychain is not
// written by these tests. TheWindowsStoreCanBeListed becomes a listing of the keychain that must not fail. The tests of
// CertificateReadersTests that read text, a display copy and signatures with a certificate belong to the viewer and the
// engine, which take a PdfCertificate whatever its source.

final class MacCertificatesTests: XCTestCase {
    private func at(_ date: Date) -> DateTimeOffset {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return DateTimeOffset(c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private func pfx(_ name: String, from: Date = Date().addingTimeInterval(-86400), years: Int = 1, password: String = "pw") throws -> [UInt8] {
        let certificate = try PdfDigitalId.create(name, nil, at(from), years: years, keyBits: 2048)
        return try PdfDigitalId.exportPfx(certificate, password)
    }

    private func choice(_ name: String, valid: Bool) -> CertificateChoice {
        CertificateChoice(id: name, name: name, issuer: "Test", expires: Date(), isValidNow: valid)
    }

    func test_validOnesComeFirstThenByName() {
        let ordered = MacCertificates.order([choice("Zeta", valid: true), choice("Expired", valid: false), choice("alpha", valid: true)])

        XCTAssertEqual(ordered.map(\.name), ["alpha", "Zeta", "Expired"])
        XCTAssertEqual(ordered.map(\.isValidNow), [true, true, false])
    }

    func test_anImportedIdentityIsOfferedWithItsNameAndIssuer() throws {
        let keys = MacCertificates()

        let imported = try keys.importIdentity(try pfx("Carol"), password: "pw", keep: false)

        XCTAssertEqual(imported.name, "Carol")
        XCTAssertEqual(imported.issuer, "Carol")
        XCTAssertTrue(imported.isValidNow)
        XCTAssertTrue(imported.expires > Date())
        XCTAssertEqual(keys.choices().filter { $0.id == imported.id }, [imported])
    }

    func test_anExpiredIdentityIsOfferedButNotValid() throws {
        let keys = MacCertificates()
        let old = Date().addingTimeInterval(-3 * 365 * 86400)

        let imported = try keys.importIdentity(try pfx("Old", from: old, years: 1), password: "pw", keep: false)

        XCTAssertFalse(imported.isValidNow)
        XCTAssertTrue(imported.expires < Date())
    }

    func test_aWrongPasswordImportsNothing() throws {
        let keys = MacCertificates()

        XCTAssertThrowsError(try keys.importIdentity(try pfx("Dave"), password: "wrong", keep: false))
        XCTAssertTrue(keys.choices().filter { $0.name == "Dave" }.isEmpty)
    }

    func test_bytesThatAreNoPfxImportNothing() {
        XCTAssertThrowsError(try MacCertificates().importIdentity([1, 2, 3], password: "pw", keep: false))
    }

    func test_theKeychainCanBeListed() {
        XCTAssertNoThrow(MacCertificates().choices())
    }

    private func encrypted(for certificate: X509Certificate) throws -> [UInt8] {
        let recipient = PdfRecipient(try XCTUnwrap(PdfCertificate(certificate)))
        let security = try PdfSecurity.createPublicKey([recipient], .aes256)
        return try PdfDocument.open(try MacPdfs.text()).saveRewrite(PdfSaveOptions(security: security))
    }

    func test_aFileForRecipientsOpensWithTheImportedIdentity() throws {
        let made = try PdfDigitalId.create("Alice", nil, at(Date().addingTimeInterval(-86400)), years: 1, keyBits: 2048)
        let keys = MacCertificates()
        let alice = try keys.importIdentity(try PdfDigitalId.exportPfx(made, "pw"), password: "pw", keep: false)
        let bytes = try encrypted(for: made)

        XCTAssertThrowsError(try PdfEditSession.open(bytes))
        let session = try keys.open(bytes, alice)

        XCTAssertEqual(session.document.pages.count, 1)
    }

    func test_anIdentityThatIsNotARecipientDoesNotOpenTheFile() throws {
        let made = try PdfDigitalId.create("Alice", nil, at(Date().addingTimeInterval(-86400)), years: 1, keyBits: 2048)
        let keys = MacCertificates()
        let mallory = try keys.importIdentity(try pfx("Mallory"), password: "pw", keep: false)
        let bytes = try encrypted(for: made)

        XCTAssertThrowsError(try keys.open(bytes, mallory)) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .certificateRequired)
        }
    }

    func test_aChoiceThatIsNotInTheKeychainIsNotARecipient() throws {
        let unknown = choice("nobody", valid: true)

        XCTAssertThrowsError(try MacCertificates().open(try MacPdfs.text(), unknown)) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .certificateRequired)
        }
    }
}
#endif
