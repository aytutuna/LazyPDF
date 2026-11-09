import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/SigningSettingsTests.cs: what the person decided about trust and time stamp servers,
// kept in signing.json. SigningSettings of Windows is SignatureTrust here; its Verify is verifyOptions. The certificates are
// made by the engine where there is one that can.

final class SigningSettingsTests: XCTestCase {
    private let now = DateTimeOffset(2026, 3, 10, 9, 0, 0)

    private func trust(_ directory: TempDir) -> SignatureTrust {
        SignatureTrust(directory: directory.url)
    }

    func test_systemRootsAreTrustedUntilThePersonSaysOtherwise() {
        let loaded = trust(TempDir(self))

        XCTAssertTrue(loaded.trustsSystem)
        XCTAssertTrue(loaded.rows.isEmpty)
        XCTAssertEqual(loaded.timestampUrl, "")
    }

    #if canImport(Security)
    private func ada() throws -> X509Certificate {
        try PdfDigitalId.create("Ada", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 1, keyBits: 2048)
    }

    func test_changesAreReadBackAndEachPartKeepsTheOthers() throws {
        let dir = TempDir(self)
        let certificate = try ada()
        trust(dir).setTimestampUrl("http://tsa.example/stamp")
        trust(dir).setTrustsSystem(false)
        XCTAssertTrue(trust(dir).add(certificate.rawData))

        let loaded = trust(dir)

        XCTAssertEqual(loaded.timestampUrl, "http://tsa.example/stamp")
        XCTAssertFalse(loaded.trustsSystem)
        XCTAssertEqual(loaded.rows.count, 1)
    }

    func test_theVerifierGetsTheAnchorsAndSkipsWhatDoesNotParse() throws {
        let dir = TempDir(self)
        let certificate = try ada()
        let file = """
        {"trustWindowsStore": false, "trustedCertificates": ["\(Data(certificate.rawData).base64EncodedString())", "not base64!", "\(Data([1, 2, 3]).base64EncodedString())"]}
        """
        dir.file("signing.json", Array(file.utf8))

        let options = trust(dir).verifyOptions(password: "secret", now: now)

        XCTAssertFalse(options.useSystemStore)
        XCTAssertEqual(options.trustAnchors.map(\.thumbprint), [certificate.thumbprint])
        XCTAssertEqual(options.password, "secret")
        XCTAssertEqual(options.now?.unixSeconds, now.unixSeconds)
    }

    func test_aCertificateAsPemIsReadByTheLoader() throws {
        let dir = TempDir(self)
        let certificate = try ada()
        let body = Data(certificate.rawData).base64EncodedString(options: .lineLength64Characters)
        let pem = Array("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8)

        XCTAssertTrue(trust(dir).add(pem))

        XCTAssertEqual(trust(dir).verifyOptions(password: nil, now: now).trustAnchors.map(\.thumbprint), [certificate.thumbprint])
    }
    #endif
}
