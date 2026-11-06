#if canImport(Security)
import Foundation
import Security

// Twin of windows/LazyPDF.Core/Signatures/PdfDigitalId.cs: a self-signed certificate for people who have none.
// Signatures made with it show as "not trusted" everywhere but where it is added as trusted by hand. Apple-only: the
// key is a SecKey. The certificate is written by CertificateBuilder, since Security.framework has no certificate writer.

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

    /// The certificate and its private key as a PFX file protected by `password`. Only macOS can write a PKCS#12 file
    /// (SecItemExport); iOS has no call for it and says so.
    public static func exportPfx(_ certificate: X509Certificate, _ password: String) throws -> [UInt8] {
        #if os(macOS)
        guard let key = certificate.privateKey else { throw SignatureCryptoException(message: "The certificate has no private key to export.") }
        guard let item = SecCertificateCreateWithData(nil, Data(certificate.rawData) as CFData) else {
            throw SignatureCryptoException(message: "The certificate could not be read.")
        }
        var parameters = SecItemImportExportKeyParameters()
        let secret = password as CFString
        parameters.version = 0
        parameters.passphrase = Unmanaged<CFTypeRef>.passUnretained(secret as CFTypeRef)
        var data: CFData?
        let status = SecItemExport([item, key] as CFArray, .formatPKCS12, [], &parameters, &data)
        guard status == errSecSuccess, let data else { throw SignatureCryptoException(message: "The PFX file could not be written.") }
        return [UInt8](data as Data)
        #else
        throw PdfReadException(.unsupported, "A PFX file cannot be written on this platform.")
        #endif
    }

    /// The certificate with its key. On macOS the key stays in memory only, as `EphemeralKeySet` does; on iOS
    /// SecPKCS12Import puts it in the app's keychain.
    public static func importPfx(_ pfx: [UInt8], _ password: String) throws -> X509Certificate {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        options[kSecImportToMemoryOnly as String] = true
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(Data(pfx) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]],
              let identity = list.first?[kSecImportItemIdentity as String] as? SecIdentity else {
            throw SignatureCryptoException(message: "The PFX file could not be read; the password may be wrong.")
        }
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let parsed = X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data)) else {
            throw SignatureCryptoException(message: "The PFX file holds no certificate with a key.")
        }
        parsed.privateKey = key
        return parsed
    }

    // A comma or a quote in a name would end its attribute early.
    private static func escape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
#endif
