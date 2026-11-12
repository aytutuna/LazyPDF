#if canImport(Security)
import XCTest
import Security
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/protect/RecipientSourceTests.cs. The certificate files are bytes, since the file
// picker of an Apple platform gives a grant and not a path. The curve certificate is a fixed one made with OpenSSL, because
// the engine builds RSA certificates only.

final class RecipientSourceTests: XCTestCase {
    // Made with openssl req -x509 -newkey ec; the curve is in the name of the constant.
    private static let p384 = "MIIBtDCCATqgAwIBAgIUEVXL7Q2JleAndMPj3rN1kN3E4QswCgYIKoZIzj0EAwIwEDEOMAwGA1UEAwwFQ3VydmUwIBcNMjYxMTEyMjI0NTUyWhgPMjEyNjEwMTkyMjQ1NTJaMBAxDjAMBgNVBAMMBUN1cnZlMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEP2Nm553uz1CuKi5l7cHbA9Q/rFOQHR5imU5J/fHM9IFoj9OT/CACJCtZzJo5cgHArFfMeEDZBDhoP5I2w2OgxpCsSN4zo5DK0V+Ytows2HepgJRAae9oDtOC+THMkMaUo1MwUTAdBgNVHQ4EFgQUf/jk38pNzY1Xpdli1NLYcrI2+/cwHwYDVR0jBBgwFoAUf/jk38pNzY1Xpdli1NLYcrI2+/cwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNoADBlAjBbP4K9VHVj7EB8mlXjqvHTy4POdxRu+2qUL2KunFHBmA670dSHpd6XyjnXy4f3maYCMQCSb061VEgme8ZysH3nEZBSFcXzV5LQswJoDm1jBTkLK4+aOCP8iOwde9OGCwmX6yg="
    private static let p521 = "MIIB/zCCAWCgAwIBAgIUZKoUn6cl7ng4rPZbQCjsZe84UCQwCgYIKoZIzj0EAwIwEDEOMAwGA1UEAwwFQ3VydmUwIBcNMjYxMTEyMjI0NTUyWhgPMjEyNjEwMTkyMjQ1NTJaMBAxDjAMBgNVBAMMBUN1cnZlMIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQAwG8vmGHlaOg5AZAd76zICndjGiakXfsQA4HCDwn7LdpiCtyEYZSTbHouU0kHQk1p5mkolxRgO8u7JPk8d/92nGoBQK4GhS4TTGKmt85oDuqn8iTXyOMCmQ+BLKJ2Ljzlik5OGkUkvEPlPRmL+wbtcj6iFx0hhncK6TPlrj5T/hMkT2WjUzBRMB0GA1UdDgQWBBR7PqQpYh3fmyuEmycHwIvNb4mOxzAfBgNVHSMEGDAWgBR7PqQpYh3fmyuEmycHwIvNb4mOxzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA4GMADCBiAJCAfwXmPN4eLE5kDaifatwkGJd+BMyyuv58JN3cACg70lmfhLxVs2/XsnJdNbyApW4Mlb3bHRHH1fkRm6ivS46yV/pAkIBbYEla9wswNPzRVyjvFNBK39vdEnXtZXRgNcUnkuJnsliS7Jp3N4D03hOQY2lQEU+ihc5uNAnpz3JEhOduBtYD7U="
    private static let curve = "MIIBdjCCAR2gAwIBAgIUaAHI6EWNDA8p9tPk/orDCauxgmwwCgYIKoZIzj0EAwIwEDEOMAwGA1UEAwwFQ3VydmUwIBcNMjYxMTA5MDAwODM4WhgPMjEyNjEwMTYwMDA4MzhaMBAxDjAMBgNVBAMMBUN1cnZlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAERIXFnGEtvOPzrS4J1i4qd3m5DwvBGIHWJmrlf+V411mEWMrhDUc5CsPfkCR9ZPWIkM0f5zE/JLr67jmKjH8GYaNTMFEwHQYDVR0OBBYEFJt0tM9egX8t+xHBVJLC3TTz2MjaMB8GA1UdIwQYMBaAFJt0tM9egX8t+xHBVJLC3TTz2MjaMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgGaF51i3WYsM+QcQ5u9BMwLYhuWIznGa2FNswuSY8wXcCIGTr6UoGVrFK7hAwmUQP6NJ0xEL+KWTeF4n2/CyGRCDI"

    private func rsaCertificate() throws -> [UInt8] {
        try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048, encipher: true).rawData
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

    func test_aCertificateWithAKeyAgreementCurveIsRead() throws {
        for encoded in [Self.curve, Self.p384] {
            let der = try XCTUnwrap(Data(base64Encoded: encoded))

            let recipient = try XCTUnwrap(RecipientSource.fromFile([UInt8](der)))

            XCTAssertEqual(recipient.name, "Curve")
            XCTAssertFalse(recipient.hasPrivateKey)
        }
    }

    func test_aCertificateWithAnUnsupportedCurveIsRefused() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.p521))

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
