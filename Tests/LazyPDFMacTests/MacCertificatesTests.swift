#if os(macOS)
import XCTest
import Security
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit

// Mirrors windows/LazyPDF.App.Tests/WindowsCertificatesTests.cs and CertificateReadersTests.cs. The identities are .p12
// files made here and read through the engine; the keychain is not written by the tests, except the one that imports for
// good and removes the identity again. OnlyCertificatesWithAPrivateKeyAreOffered becomes a test of the key check, since a
// keychain identity always has a key. TheTabKeepsTheCertificateItWasOpenedWith tests the tab, which is the shell's.

final class MacCertificatesTests: XCTestCase {
    private static func at(_ date: Date) -> DateTimeOffset {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return DateTimeOffset(c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func identity(_ name: String, from: Date = Date().addingTimeInterval(-86400), years: Int = 1) throws -> X509Certificate {
        try PdfDigitalId.create(name, nil, at(from), years: years, keyBits: 2048, encipher: true)
    }

    private func pfx(_ name: String, from: Date = Date().addingTimeInterval(-86400), years: Int = 1, password: String = "pw") throws -> [UInt8] {
        try PdfDigitalId.exportPfx(try Self.identity(name, from: from, years: years), password)
    }

    static func encrypted(for certificate: X509Certificate) throws -> [UInt8] {
        let recipient = PdfRecipient(try XCTUnwrap(PdfCertificate(certificate)))
        let security = try PdfSecurity.createPublicKey([recipient], .aes256)
        return try PdfDocument.open(try MacPdfs.text()).saveRewrite(PdfSaveOptions(security: security))
    }

    private func choice(_ name: String, valid: Bool) -> CertificateChoice {
        CertificateChoice(id: name, name: name, issuer: "Test", expires: Date(), isValidNow: valid)
    }

    func test_aChoiceCarriesItsThumbprintAndIssuer() throws {
        let keys = MacCertificates()
        let made = try Self.identity("Carol")

        let imported = try keys.importIdentity(try PdfDigitalId.exportPfx(made, "pw"), password: "pw", keep: false).choice

        XCTAssertEqual(imported.id, made.thumbprint)
        XCTAssertEqual(imported.name, "Carol")
        XCTAssertEqual(imported.issuer, "Carol")
        XCTAssertTrue(imported.isValidNow)
        XCTAssertTrue(imported.expires > Date())
        XCTAssertEqual(keys.choices().filter { $0.id == imported.id }, [imported])
    }

    func test_anExpiredIdentityIsOfferedButNotValid() throws {
        let keys = MacCertificates()
        let old = Date().addingTimeInterval(-3 * 365 * 86400)

        let imported = try keys.importIdentity(try pfx("Old", from: old, years: 1), password: "pw", keep: false).choice

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

    func test_everyChoiceOfTheKeychainOpensAFile() {
        let keys = MacCertificates()

        for choice in keys.choices() { XCTAssertNotNil(keys.certificate(for: choice), choice.name) }
    }

    func test_onlyAKeyThatCanSignOrDecryptIsOffered() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))

        XCTAssertTrue(MacCertificates.canUse(key))
        XCTAssertFalse(MacCertificates.canUse(publicKey))
    }

    func test_anIdentityImportedForGoodIsInTheKeychainAfterwards() throws {
        let name = "Lazy PDF test " + UUID().uuidString
        addTeardownBlock { Self.removeFromKeychain(name) }

        let result = try MacCertificates().importIdentity(try pfx(name), password: "pw")

        XCTAssertTrue(result.kept)
        XCTAssertTrue(MacCertificates().choices().contains { $0.name == name })
    }

    private static func removeFromKeychain(_ name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { return }
        for identity in identities {
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            if let certificate, (SecCertificateCopySubjectSummary(certificate) as String?) == name {
                SecItemDelete([kSecValueRef as String: identity] as CFDictionary)
            }
        }
    }

    private func alice() throws -> (made: X509Certificate, keys: MacCertificates, choice: CertificateChoice, bytes: [UInt8]) {
        let made = try Self.identity("Alice")
        let keys = MacCertificates()
        let choice = try keys.importIdentity(try PdfDigitalId.exportPfx(made, "pw"), password: "pw", keep: false).choice
        return (made, keys, choice, try Self.encrypted(for: made))
    }

    func test_aFileForRecipientsOpensWithTheImportedIdentity() throws {
        let a = try alice()

        XCTAssertThrowsError(try PdfEditSession.open(a.bytes))
        let session = try a.keys.open(a.bytes, a.choice)

        XCTAssertEqual(session.document.pages.count, 1)
    }

    func test_theCertificateForCheckingSignaturesOpensTheFile() throws {
        let a = try alice()

        let x509 = try XCTUnwrap(a.keys.verifyCertificate(a.choice))
        let session = try PdfEditSession.open(a.bytes, certificate: try XCTUnwrap(PdfCertificate(x509)))

        XCTAssertEqual(session.document.pages.count, 1)
        XCTAssertNil(a.keys.verifyCertificate(choice("nobody", valid: true)))
    }

    func test_anIdentityThatIsNotARecipientDoesNotOpenTheFile() throws {
        let a = try alice()
        let keys = MacCertificates()
        let mallory = try keys.importIdentity(try pfx("Mallory"), password: "pw", keep: false).choice

        XCTAssertThrowsError(try keys.open(a.bytes, mallory)) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .certificateRequired)
        }
    }

    func test_aChoiceThatIsNotInTheKeychainIsNotARecipient() throws {
        XCTAssertThrowsError(try MacCertificates().open(try MacPdfs.text(), choice("nobody", valid: true))) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .certificateRequired)
        }
    }

    func test_theCertificateOfAChoiceIsFoundAgain() throws {
        let a = try alice()

        XCTAssertNotNil(a.keys.certificate(for: a.choice))
        XCTAssertNil(a.keys.certificate(for: choice("nobody", valid: true)))
    }

    func test_textIsReadFromAFileForRecipients() async throws {
        let a = try alice()
        let identity = try XCTUnwrap(a.keys.certificate(for: a.choice))

        let source = await TextSource.open(a.bytes, certificate: identity)

        let page = await source?.get(0)
        XCTAssertTrue(try XCTUnwrap(page).text.contains("Hello"))
    }

    func test_aDisplayCopyIsMadeFromAFileForRecipients() throws {
        let a = try alice()
        let identity = try XCTUnwrap(a.keys.certificate(for: a.choice))

        XCTAssertNil(DisplayCopy.create(a.bytes, password: nil, changes: [], makeRenderer: { PdfKitRenderer() }))
        let copy = try XCTUnwrap(DisplayCopy.create(a.bytes, certificate: identity, changes: [], makeRenderer: { PdfKitRenderer() }))

        XCTAssertNotNil(copy.renderer.render(0, 72))
    }

    func test_signaturesAreCheckedInAFileForRecipients() throws {
        let a = try alice()
        var options = VerifyOptions()
        options.certificate = a.made

        XCTAssertThrowsError(try PdfSignatureVerifier.verify(a.bytes))
        XCTAssertTrue(try PdfSignatureVerifier.verify(a.bytes, options).isEmpty)
    }
}
#endif
