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
        let written = exportViaKeychain(item, key, password)
        guard let bytes = written.bytes else { throw SignatureCryptoException(message: "The PFX file could not be written (\(written.steps)).") }
        return bytes
        #else
        throw PdfReadException(.unsupported, "A PFX file cannot be written on this platform.")
        #endif
    }

    #if os(macOS)
    private static func export(_ item: CFTypeRef, _ password: String) -> (bytes: [UInt8]?, status: OSStatus) {
        var parameters = SecItemImportExportKeyParameters()
        let secret = password as CFString
        parameters.version = 0
        parameters.passphrase = Unmanaged<CFTypeRef>.passUnretained(secret as CFTypeRef)
        var data: CFData?
        let status = SecItemExport(item, .formatPKCS12, [], &parameters, &data)
        guard status == errSecSuccess, let data else { return (nil, status) }
        return ([UInt8](data as Data), status)
    }

    // SecItemExport does not take a key made in memory next to its certificate (it answers paramErr); it writes an
    // identity. So the key goes into a keychain of its own as its PKCS#1 form (RSA only), which gives it the label
    // that ties it to its certificate. Nothing may ask the user: a question here would wait for ever. `steps` names the
    // status of each call, since the statuses of this framework say little alone.
    private static func exportViaKeychain(_ certificate: SecCertificate, _ key: SecKey, _ password: String) -> (bytes: [UInt8]?, steps: String) {
        guard let representation = SecKeyCopyExternalRepresentation(key, nil) else { return (nil, "key \(errSecParam)") }
        let path = NSTemporaryDirectory() + "lazypdf-" + UUID().uuidString + ".keychain"
        let secret = Array(password.utf8)
        var created: SecKeychain?
        let made = SecKeychainCreate(path, UInt32(secret.count), secret, false, nil, &created)
        guard made == errSecSuccess, let keychain = created else { return (nil, "keychain \(made)") }
        defer { SecKeychainDelete(keychain) }
        var asked = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&asked)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(asked.boolValue) }

        var steps = "keychain \(made)"
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = 0
        parameters.flags = .noAccessControl
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePrivateKey
        var imported = SecItemImport(representation, nil, &format, &type, [], &parameters, keychain, nil)
        steps += ", import \(imported)"
        if imported != errSecSuccess {
            format = .formatOpenSSL
            type = .itemTypePrivateKey
            imported = SecItemImport(representation, nil, &format, &type, [], nil, keychain, nil)
            steps += ", import without parameters \(imported)"
        }
        if imported != errSecSuccess { return (nil, steps) }
        var identity: SecIdentity?
        var found = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        steps += ", identity \(found)"
        if found != errSecSuccess {
            let list: [AnyObject] = [keychain]
            found = SecIdentityCreateWithCertificate(list as CFArray, certificate, &identity)
            steps += ", identity in a list \(found)"
        }
        guard found == errSecSuccess, let identity else { return (nil, steps) }
        let written = export(identity, password)
        steps += ", export \(written.status)"
        return (written.bytes, steps)
    }
    #endif

    /// The certificate with its key. From macOS 15 the key stays in memory only, as `EphemeralKeySet` does; before that
    /// and on iOS SecPKCS12Import puts it in the keychain.
    public static func importPfx(_ pfx: [UInt8], _ password: String) throws -> X509Certificate {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(Data(pfx) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]],
              let found = list.first?[kSecImportItemIdentity as String], CFGetTypeID(found as AnyObject) == SecIdentityGetTypeID() else {
            throw SignatureCryptoException(message: "The PFX file could not be read; the password may be wrong.")
        }
        // Swift checks no CoreFoundation type on a cast, so the type is checked above; the dictionary is the framework's own.
        let identity = found as! SecIdentity
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
