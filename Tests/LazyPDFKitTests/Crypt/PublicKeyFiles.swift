#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Crypt/PublicKeyFiles.cs, without Plain, Seal and Content, which need
// PdfDocument and are in Document/PublicKeyDocumentFiles.swift. The certificates are made once per run.

enum PublicKeyFiles {
    static let alice = certificate("First")
    static let bob = certificate("Second")
    static let eve = certificate("Stranger")

    /// A self-signed RSA certificate with its private key.
    static func certificate(_ name: String) -> PdfCertificate {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeySizeInBits as String: 2048]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            preconditionFailure("The system made no RSA key.")
        }
        let der = TestCertificate.der(name, publicKey: [UInt8](pkcs1)) { tbs in
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, nil) as Data?
            return [UInt8](signature ?? Data())
        }
        guard let made = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            preconditionFailure("The system did not read the certificate.")
        }
        return PdfCertificate(certificate: made, privateKey: privateKey)
    }

    /// A self-signed elliptic curve certificate with its private key; `usage` is the encoded key usage bit string.
    static func ecCertificate(_ name: String, bits: Int = 256, usage: [UInt8] = [0x03, 0x02, 0x03, 0x08]) -> PdfCertificate {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeySizeInBits as String: bits]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            preconditionFailure("The system made no EC key.")
        }
        let curve = bits == 256 ? PdfCms.curveP256 : bits == 384 ? PdfCms.curveP384 : PdfCms.curveP521
        let der = TestCertificate.derEc(name, curve: curve, publicPoint: [UInt8](point), usage: usage) { tbs in
            let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, nil) as Data?
            return [UInt8](signature ?? Data())
        }
        guard let made = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            preconditionFailure("The system did not read the certificate.")
        }
        return PdfCertificate(certificate: made, privateKey: privateKey)
    }

    /// The certificate alone, as a recipient list or an address book has it.
    static func publicPart(_ certificate: PdfCertificate) -> PdfCertificate {
        PdfCertificate(certificate: certificate.certificate)
    }
}
#endif
