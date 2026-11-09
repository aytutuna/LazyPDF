#if canImport(Security)
import XCTest
import Security
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/protect/RecipientSourceTests.cs. The certificate files are bytes, since the file
// picker of an Apple platform gives a grant and not a path. The curve certificate is a fixed one made with OpenSSL, because
// the engine builds RSA certificates only.

final class RecipientSourceTests: XCTestCase {
    private static let curve = "MIIBdjCCAR2gAwIBAgIUaAHI6EWNDA8p9tPk/orDCauxgmwwCgYIKoZIzj0EAwIwEDEOMAwGA1UEAwwFQ3VydmUwIBcNMjYxMTA5MDAwODM4WhgPMjEyNjEwMTYwMDA4MzhaMBAxDjAMBgNVBAMMBUN1cnZlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAERIXFnGEtvOPzrS4J1i4qd3m5DwvBGIHWJmrlf+V411mEWMrhDUc5CsPfkCR9ZPWIkM0f5zE/JLr67jmKjH8GYaNTMFEwHQYDVR0OBBYEFJt0tM9egX8t+xHBVJLC3TTz2MjaMB8GA1UdIwQYMBaAFJt0tM9egX8t+xHBVJLC3TTz2MjaMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgGaF51i3WYsM+QcQ5u9BMwLYhuWIznGa2FNswuSY8wXcCIGTr6UoGVrFK7hAwmUQP6NJ0xEL+KWTeF4n2/CyGRCDI"

    private func rsaCertificate() throws -> [UInt8] {
        try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048).rawData
    }

    private func pem(_ der: [UInt8]) -> [UInt8] {
        let body = Data(der).base64EncodedString(options: .lineLength64Characters)
        return Array("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8)
    }

    func test_aCertificateFileInEitherFormIsRead() throws {
        let der = try rsaCertificate()

        let fromDer = try XCTUnwrap(RecipientSource.fromFile(der))
        let fromPem = try XCTUnwrap(RecipientSource.fromFile(pem(der)))

        XCTAssertEqual(fromDer.name, "Ada Lovelace")
        XCTAssertEqual(fromDer.thumbprint, fromPem.thumbprint)
        XCTAssertFalse(fromDer.hasPrivateKey)
    }

    func test_aStoreThatDoesNotExistIsSkipped() {
        _ = RecipientSource.fromStore()
    }

    func test_aFileThatIsNotACertificateIsRefused() {
        XCTAssertNil(RecipientSource.fromFile(Array("not a certificate".utf8)))
    }

    func test_aCertificateWithoutAnRsaKeyIsRefused() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.curve))

        XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertNil(RecipientSource.fromFile([UInt8](der)))
    }

    func test_aDetailLineSaysWhoIssuedItAndUntilWhen() throws {
        let recipient = try XCTUnwrap(RecipientSource.fromFile(rsaCertificate()))

        XCTAssertFalse(recipient.expired())
        XCTAssertTrue(recipient.details().contains("Ada Lovelace"))
        XCTAssertTrue(recipient.details().contains(recipient.notAfter.formatted(date: .numeric, time: .omitted)))
        XCTAssertTrue(recipient.expired(now: recipient.notAfter.addingTimeInterval(86400)))
    }
}
#endif
