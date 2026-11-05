#if canImport(Security)
import Foundation
import Security

// Twin of windows/LazyPDF.Core/Signatures/PdfDigitalId.cs: a self-signed certificate for people who have none.
// Signatures made with it show as "not trusted" everywhere but where it is added as trusted by hand. Apple-only: the
// key is a SecKey. The certificate is written by CertificateBuilder, since Security.framework has no certificate writer.
//
// Left out against the C#: ExportPfx. Security.framework reads a PKCS#12 file (SecPKCS12Import) but writes one only
// from a keychain item, so it throws `unsupported` here; the file the user keeps would have to come from a PKCS#12
// writer of our own.

public enum PdfDigitalId {
    private static let emailProtection = "1.3.6.1.5.5.7.3.4"
    private static let pdfSigning = "1.2.840.113583.1.1.5"

    /// A certificate for `name` (and `email` when given) valid for `years` from `notBefore`, which is the caller's
    /// clock. The key is an RSA key of `keyBits`, held by the certificate and not kept in a keychain.
    public static func create(_ name: String, _ email: String?, _ notBefore: DateTimeOffset, years: Int = 10, keyBits: Int = 3072) throws -> X509Certificate {
        guard let notAfter = notBefore.adding(years: years) else { throw ArgumentException("years") }
        let subject = X509Certificate.name(email.map { $0.isEmpty ? "CN=\(escape(name))" : "CN=\(escape(name)), E=\(escape($0))" } ?? "CN=\(escape(name))")
        let key = try SignatureCrypto.newRsaKey(keyBits)
        let info = try CertificateBuilder.publicKeyInfo(key)
        var extensions = [
            CertificateBuilder.basicConstraints(authority: false),
            CertificateBuilder.keyUsage([.digitalSignature, .nonRepudiation]),
            CertificateBuilder.enhancedKeyUsage([emailProtection, pdfSigning]),
            CertificateBuilder.subjectKeyIdentifier(info),
        ]
        if let email, !email.isEmpty { extensions.append(CertificateBuilder.subjectAlternativeEmail(email)) }
        let der = try CertificateBuilder.build(subject: subject, issuer: subject, publicKeyInfo: info, notBefore: notBefore, notAfter: notAfter,
                                               serial: CertificateBuilder.serialNumber(), extensions: extensions, issuerKey: key)
        guard let certificate = X509Certificate(der) else { throw SignatureCryptoException(message: "The certificate could not be read back.") }
        certificate.privateKey = key
        return certificate
    }

    /// The certificate and its private key as a PFX file protected by `password`.
    public static func exportPfx(_ certificate: X509Certificate, _ password: String) throws -> [UInt8] {
        throw PdfReadException(.unsupported, "A PFX file cannot be written on this platform.")
    }

    /// The certificate with its key held in memory only where the platform allows it.
    public static func importPfx(_ pfx: [UInt8], _ password: String) throws -> X509Certificate {
        var items: CFArray?
        let status = SecPKCS12Import(Data(pfx) as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let identity = first[kSecImportItemIdentity as String] as? SecIdentity else {
            throw SignatureCryptoException(message: "The PFX file could not be opened with that password.")
        }
        var sec: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &sec) == errSecSuccess, let sec,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let certificate = X509Certificate([UInt8](SecCertificateCopyData(sec) as Data)) else {
            throw SignatureCryptoException(message: "The PFX file holds no usable identity.")
        }
        certificate.privateKey = key
        return certificate
    }

    // A comma or a quote in a name would end its attribute early.
    private static func escape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
#endif
