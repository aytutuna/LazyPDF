#if canImport(Security)
import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// What the tests of the Certificates tool share: a transport that no server answers, a transport that says why, and the
// certificates and signed files they sign and verify with.

final class SilentServer: SignatureTransport {
    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? { nil }
    func get(_ url: String) -> [UInt8]? { nil }
}

/// A server that cancels the run the moment it is asked, and gives nothing.
final class CancelsOnRequest: SignatureTransport {
    private let token: CancelToken

    init(_ token: CancelToken) {
        self.token = token
    }

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        token.cancel()
        return nil
    }

    func get(_ url: String) -> [UInt8]? {
        token.cancel()
        return nil
    }
}

/// A server that cannot be reached, and says why.
final class DownServer: SigningTransport {
    var lastFailure: String? = "The server did not answer."
    private(set) var cancelled = 0

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? { nil }
    func get(_ url: String) -> [UInt8]? { nil }
    func cancel() { cancelled += 1 }
}

/// A server that holds a request until the test lets it go, whatever Cancel says.
final class HeldServer: SigningTransport {
    let lastFailure: String? = nil
    let arrived = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        arrived.signal()
        release.wait()
        return nil
    }

    func get(_ url: String) -> [UInt8]? { nil }
    func cancel() {}
    func letGo() { release.signal() }
}

enum CertificateKit {
    static let now = DateTimeOffset(2026, 3, 10, 9, 0, 0)

    static func ada() throws -> X509Certificate {
        try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 2, keyBits: 2048)
    }

    static func plain(_ certificate: X509Certificate) -> SignChoices {
        SignChoices(certificate: certificate, field: nil, page: 0, rect: nil, reason: "", location: "", certify: .none, timestampUrl: nil,
                    longTerm: false)
    }

    static func options(trusting: [X509Certificate] = []) throws -> VerifyOptions {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trust = SignatureTrust(directory: folder)
        trust.setTrustsSystem(false)
        for certificate in trusting { XCTAssertTrue(trust.add(certificate.rawData)) }
        return trust.verifyOptions(password: nil, now: now)
    }

    // A signer whose certificate names an OCSP responder, issued by an authority the file carries.
    static func issued() throws -> (signer: X509Certificate, authority: X509Certificate) {
        let start = DateTimeOffset(2026, 2, 1, 9, 0, 0)
        let end = DateTimeOffset(2031, 3, 10, 9, 0, 0)
        let authorityKey = try SignatureCrypto.newRsaKey(2048)
        let authorityInfo = try CertificateBuilder.publicKeyInfo(authorityKey)
        let authorityName = X509Certificate.name("CN=Test Authority")
        let authorityDer = try CertificateBuilder.build(
            subject: authorityName, issuer: authorityName, publicKeyInfo: authorityInfo, notBefore: start, notAfter: end,
            serial: CertificateBuilder.serialNumber(), extensions: [
                CertificateBuilder.basicConstraints(authority: true), CertificateBuilder.keyUsage([.keyCertSign, .crlSign]),
                CertificateBuilder.subjectKeyIdentifier(authorityInfo),
            ], issuerKey: authorityKey)
        let authority = try XCTUnwrap(X509Certificate(authorityDer))
        authority.privateKey = authorityKey

        let key = try SignatureCrypto.newRsaKey(2048)
        let info = try CertificateBuilder.publicKeyInfo(key)
        let access = DerWriter.sequence([DerWriter.sequence([DerWriter.oid("1.3.6.1.5.5.7.48.1"), DerWriter.ia5String("http://ocsp.example/", tag: 0x86)])])
        let der = try CertificateBuilder.build(
            subject: X509Certificate.name("CN=Grace Hopper"), issuer: authorityName, publicKeyInfo: info,
            notBefore: DateTimeOffset(2026, 3, 9, 9, 0, 0), notAfter: end, serial: CertificateBuilder.serialNumber(), extensions: [
                CertificateBuilder.basicConstraints(authority: false), CertificateBuilder.keyUsage([.digitalSignature]),
                X509Extension(oid: "1.3.6.1.5.5.7.1.1", critical: false, value: access),
            ], issuerKey: authorityKey)
        let signer = try XCTUnwrap(X509Certificate(der))
        signer.privateKey = key
        return (signer, authority)
    }

    static func signedByGrace() throws -> PdfEditSession {
        let (signer, authority) = try issued()
        let session = try PdfEditSession.open(Pdfs.text())
        var request = PdfSignRequest(signer, CertificateKit.now)
        request.chain = [authority]
        request.fonts = FakeFonts()
        try PdfSigner.sign(session, request)
        return session
    }
}

#endif
