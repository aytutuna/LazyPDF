#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/DigitalIdTests.cs: the same cases. The wrong-password case expects any
// thrown error, as the C# expects any CryptographicException. The tests after the round trip hold what the C# pins in
// SignatureHardeningTests (the protection of the file), an EC key, and that an import leaves no key in a keychain.

final class DigitalIdTests: XCTestCase {
    private let start = DateTimeOffset(2026, 3, 1, 0, 0, 0)

    private func keySize(_ certificate: X509Certificate) throws -> Int {
        var outer = AsnReader(certificate.encodedKeyValue)
        var sequence = try outer.readSequence()
        let modulus = try sequence.readInteger().magnitude
        let top = modulus.first ?? 0
        return (modulus.count - 1) * 8 + (8 - top.leadingZeroBitCount)
    }

    func test_aDigitalIdIsASelfSignedCertificateForSigningWithItsKey() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", "ada@example.org", start, years: 5, keyBits: 2048)

        XCTAssertNotNil(id.privateKey)
        XCTAssertEqual(id.simpleName, "Ada Lovelace")
        XCTAssertEqual(X509Certificate.attributes(id.subjectName)?.first { $0.oid == "1.2.840.113549.1.9.1" }?.value, "ada@example.org")
        XCTAssertEqual(id.subjectName, id.issuerName)
        XCTAssertEqual(id.notBefore, start)
        XCTAssertEqual(id.notAfter, start.adding(years: 5))
        XCTAssertEqual(try keySize(id), 2048)
        let usage: KeyUsage = [.digitalSignature, .nonRepudiation]
        XCTAssertEqual(try id.keyUsage(), usage)
        XCTAssertEqual(try id.basicConstraints()?.certificateAuthority, false)
    }

    func test_thePfxCarriesTheKeyAndLoadsAgain() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)

        let pfx = try PdfDigitalId.exportPfx(id, "pass word")
        let loaded = try PdfDigitalId.importPfx(pfx, "pass word")

        XCTAssertEqual(id.thumbprint, loaded.thumbprint)
        XCTAssertNotNil(loaded.privateKey)
        XCTAssertThrowsError(try PdfDigitalId.importPfx(pfx, "wrong"))
    }

    func test_thePfxIsProtectedWithPBES2AndAES256NotTheOldTripleDES() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)

        let pfx = try PdfDigitalId.exportPfx(id, "pass word")

        let hex = pfx.map { String(format: "%02X", $0) }.joined()
        XCTAssertTrue(hex.contains("2A864886F70D01050D"))
        XCTAssertTrue(hex.contains("60864801650304012A"), "AES-256-CBC")
        XCTAssertFalse(hex.contains("2A864886F70D010C0103"))
        XCTAssertFalse(hex.contains("2A864886F70D010C0106"))
    }

    func test_aPfxTheSwiftWriterMadeBeforeLoadsToo() throws {
        let certificate = try XCTUnwrap(X509Certificate(SignatureFixtures.read("id-cert.der")))

        let loaded = try PdfDigitalId.importPfx(SignatureFixtures.read("swift-export.pfx"), SignatureFixtures.password)

        XCTAssertEqual(loaded.thumbprint, certificate.thumbprint)
        XCTAssertNotNil(loaded.privateKey)
    }

    func test_anEcKeyExportsToo() throws {
        let key = try SignatureCrypto.newEcKey()
        let info = try CertificateBuilder.publicKeyInfo(key)
        let name = X509Certificate.name("CN=Grace Hopper")
        let der = try CertificateBuilder.build(subject: name, issuer: name, publicKeyInfo: info, notBefore: Pki.notBefore, notAfter: Pki.notAfter,
                                               serial: CertificateBuilder.serialNumber(), extensions: [], issuerKey: try SignatureCrypto.newRsaKey(2048))
        let id = try XCTUnwrap(X509Certificate(der))
        id.privateKey = key

        let loaded = try PdfDigitalId.importPfx(PdfDigitalId.exportPfx(id, "pass word"), "pass word")

        XCTAssertEqual(loaded.thumbprint, id.thumbprint)
        XCTAssertNotNil(loaded.privateKey)
    }

    #if os(macOS)
    private func keychainHolds(_ certificate: X509Certificate) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let identities = found as? [SecIdentity] else { return false }
        return identities.contains { identity in
            var copy: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &copy) == errSecSuccess, let copy else { return false }
            return [UInt8](SecCertificateCopyData(copy) as Data) == certificate.rawData
        }
    }

    func test_anImportedIdLeavesNothingInTheKeychain() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        let pfx = try PdfDigitalId.exportPfx(id, "pass word")

        // The way macOS 14 takes, which a newer system takes only here, and the way the system takes.
        for loaded in [try PdfDigitalId.importPfxThroughKeychain(pfx, "pass word"), try PdfDigitalId.importPfx(pfx, "pass word")] {
            XCTAssertFalse(keychainHolds(loaded))
            XCTAssertEqual(try PdfSignatureVerifier.verify(PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(loaded, Pki.signing))).first?.verdict, .validButUntrusted)
        }
    }

    func test_theKeychainOfAnImportedIdGoesWhenTheIdDoes() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        let pfx = try PdfDigitalId.exportPfx(id, "pass word")

        var loaded: X509Certificate? = try PdfDigitalId.importPfxThroughKeychain(pfx, "pass word")
        let path = try XCTUnwrap((loaded?.keyHolder as? TemporaryKeychain)?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        loaded = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try PdfDigitalId.importPfxThroughKeychain(pfx, "wrong"))
    }

    func test_theKeychainOfAnImportedIdDoesNotLockWhileTheIdIsInUse() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        let loaded = try PdfDigitalId.importPfxThroughKeychain(PdfDigitalId.exportPfx(id, "pass word"), "pass word")
        let holder = try XCTUnwrap(loaded.keyHolder as? TemporaryKeychain)

        var settings = SecKeychainSettings(version: 1, lockOnSleep: true, useLockInterval: true, lockInterval: 300)
        XCTAssertEqual(SecKeychainCopySettings(holder.keychain, &settings), errSecSuccess)

        XCTAssertFalse(settings.lockOnSleep.boolValue)
        XCTAssertFalse(settings.useLockInterval.boolValue)
    }

    func test_aKeychainFileOfAProcessThatIsGoneIsRemovedAndOneOfThisProcessIsNot() throws {
        let folder = NSTemporaryDirectory()
        let gone = folder + "lazypdf-999999-" + UUID().uuidString + ".keychain"
        let ours = folder + "lazypdf-\(ProcessInfo.processInfo.processIdentifier)-" + UUID().uuidString + ".keychain"
        XCTAssertTrue(FileManager.default.createFile(atPath: gone, contents: Data([1])))
        XCTAssertTrue(FileManager.default.createFile(atPath: ours, contents: Data([1])))
        defer { try? FileManager.default.removeItem(atPath: ours) }

        _ = try XCTUnwrap(TemporaryKeychain("pass word"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: gone))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ours))
    }
    #endif

    func test_namesWithCommasQuotesAndTurkishLettersSurvive() throws {
        let name = "Doğan, \"Şık\" Ü."
        let id = try PdfDigitalId.create(name, nil, start, keyBits: 2048)

        XCTAssertEqual(id.simpleName, name)
    }

    func test_aSignatureWithItIsValidButNotTrustedUntilTheCallerTrustsIt() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        let signed = try PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(id, try XCTUnwrap(start.adding(days: 3))))

        let reports = try PdfSignatureVerifier.verify(signed)
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertEqual(report.sentence, "Signed by Ada Lovelace on 4 Mar 2026. The signer is not trusted.")

        var options = VerifyOptions()
        options.trustAnchors = [id]
        let trusted = try PdfSignatureVerifier.verify(signed, options)
        XCTAssertEqual(trusted.count, 1)
        XCTAssertEqual(trusted.first?.verdict, .valid)
    }
}
#endif
