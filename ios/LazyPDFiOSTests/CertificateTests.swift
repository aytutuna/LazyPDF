import XCTest
import Security
import LazyPDFKit
import LazyPDFApp
import LazyPDFIOS

// Follows windows/LazyPDF.App.Tests/WindowsCertificatesTests.cs and CertificateReadersTests.cs. The keychain of the
// simulator outlives a test, so every identity gets a name of its own and is removed again.

final class CertificateTests: XCTestCase {
    private let keys = IOSCertificates()
    private let run = String(UUID().uuidString.prefix(8))

    private func pfx(_ name: String, from: DateTimeOffset = DateTimeOffset(2020, 1, 1, 0, 0, 0), years: Int = 40) throws -> (pfx: [UInt8], certificate: X509Certificate) {
        let certificate = try PdfDigitalId.create("\(name)-\(run)", nil, from, years: years, keyBits: 2048)
        return (try PdfDigitalId.exportPfx(certificate, "secret"), certificate)
    }

    @discardableResult
    private func importIdentity(_ name: String, from: DateTimeOffset = DateTimeOffset(2020, 1, 1, 0, 0, 0), years: Int = 40) throws -> (choice: CertificateChoice, certificate: X509Certificate) {
        let made = try pfx(name, from: from, years: years)
        let choice = try keys.importIdentity(made.pfx, password: "secret")
        addTeardownBlock { Self.forget(made.certificate.thumbprint) }
        return (choice, made.certificate)
    }

    private static func forget(_ thumbprint: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let list = found as? [Any] else { return }
        for item in list {
            let identity = item as! SecIdentity
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data))?.thumbprint == thumbprint else { continue }
            SecItemDelete([kSecClass as String: kSecClassIdentity, kSecValueRef as String: identity] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
        }
    }

    private func ours() -> [CertificateChoice] {
        keys.choices().filter { $0.name.hasSuffix(run) }
    }

    private func sealed(for certificate: X509Certificate) throws -> [UInt8] {
        let recipient = PdfRecipient(try XCTUnwrap(PdfCertificate(certificate)))
        return try PdfDocument.open(samplePdf()).saveRewrite(PdfSaveOptions(security: try PdfSecurity.createPublicKey([recipient], .aes256)))
    }

    func test_anImportedIdentityIsOffered() throws {
        let made = try importIdentity("Carol")

        XCTAssertEqual(ours().map(\.id), [made.choice.id])
    }

    func test_aChoiceCarriesItsThumbprintAndIssuer() throws {
        let made = try importIdentity("Carol")

        XCTAssertEqual(made.choice.id, made.certificate.thumbprint)
        XCTAssertEqual(made.choice.name, "Carol-\(run)")
        XCTAssertEqual(made.choice.issuer, "Carol-\(run)")
    }

    func test_validOnesComeFirstThenByName() throws {
        try importIdentity("Zeta")
        try importIdentity("Expired", from: DateTimeOffset(2000, 1, 1, 0, 0, 0), years: 5)
        try importIdentity("Alpha")

        let found = ours()

        XCTAssertEqual(found.map { $0.name.components(separatedBy: "-")[0] }, ["Alpha", "Zeta", "Expired"])
        XCTAssertEqual(found.map(\.isValidNow), [true, true, false])
    }

    func test_onlyIdentitiesWithAPrivateKeyAreOffered() throws {
        let alone = try PdfDigitalId.create("Without key-\(run)", nil, DateTimeOffset(2020, 1, 1, 0, 0, 0), keyBits: 2048)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(alone.rawData) as CFData))
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        addTeardownBlock { SecItemDelete(add as CFDictionary) }
        try importIdentity("With key")

        XCTAssertEqual(ours().map { $0.name.components(separatedBy: "-")[0] }, ["With key"])
    }

    func test_aWrongPasswordImportsNothing() throws {
        let made = try pfx("Dave")

        XCTAssertThrowsError(try keys.importIdentity(made.pfx, password: "wrong"))
        XCTAssertTrue(ours().isEmpty)
    }

    func test_aFileSealedForTheIdentityOpensWithIt() throws {
        let alice = try importIdentity("Alice")

        let session = try keys.open(try sealed(for: alice.certificate), alice.choice)

        XCTAssertEqual(session.document.pages.count, 1)
    }

    func test_anIdentityThatIsNotARecipientDoesNotOpenTheFile() throws {
        let alice = try importIdentity("Alice")
        let mallory = try importIdentity("Mallory")

        XCTAssertThrowsError(try keys.open(try sealed(for: alice.certificate), mallory.choice)) { error in
            XCTAssertEqual((error as? PdfReadException)?.problem, .certificateRequired)
        }
    }

    func test_anIdentityThatLeftTheKeychainDoesNotOpenTheFile() throws {
        let alice = try importIdentity("Alice")
        let bytes = try sealed(for: alice.certificate)
        Self.forget(alice.choice.id)

        XCTAssertThrowsError(try keys.open(bytes, alice.choice)) { error in
            XCTAssertEqual((error as? PdfReadException)?.problem, .certificateRequired)
        }
    }
}
