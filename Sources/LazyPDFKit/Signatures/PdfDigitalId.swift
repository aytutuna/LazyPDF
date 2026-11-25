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
    /// clock. `encipher` adds the key usage that lets others encrypt files for this certificate. The key is an RSA key of `keyBits`, held by the certificate and not kept in a keychain.
    public static func create(_ name: String, _ email: String?, _ notBefore: DateTimeOffset, years: Int = 10, keyBits: Int = 3072, encipher: Bool = false) throws -> X509Certificate {
        guard let notAfter = notBefore.adding(years: years) else { throw ArgumentException("years") }
        let subject = X509Certificate.name(email.map { $0.isEmpty ? "CN=\(escape(name))" : "CN=\(escape(name)), E=\(escape($0))" } ?? "CN=\(escape(name))")
        let key = try SignatureCrypto.newRsaKey(keyBits)
        let info = try CertificateBuilder.publicKeyInfo(key)
        var extensions = [
            CertificateBuilder.basicConstraints(authority: false),
            CertificateBuilder.keyUsage(encipher ? [.digitalSignature, .nonRepudiation, .keyEncipherment] : [.digitalSignature, .nonRepudiation]),
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

    /// The certificate and its private key as a PFX file protected by `password`: PBES2 with AES-256 and SHA-256, as the
    /// C# writes it (Pkcs12Writer). The key must be one that exports.
    public static func exportPfx(_ certificate: X509Certificate, _ password: String) throws -> [UInt8] {
        guard let key = certificate.privateKey else { throw SignatureCryptoException(message: "The certificate has no private key to export.") }
        guard let representation = SecKeyCopyExternalRepresentation(key, nil) else {
            throw SignatureCryptoException(message: "The private key does not export.")
        }
        return try Pkcs12Writer.write(certificate, [UInt8](representation as Data), password: password)
    }

    /// The certificate with its key. From macOS 15 the key stays in memory only, as `EphemeralKeySet` does. Before that
    /// it is imported into a keychain made for the purpose, which the certificate holds and deletes when it is let
    /// go (macOS makes the imported key non-extractable, so it cannot be copied out of the keychain). iOS has no such
    /// option: SecPKCS12Import puts the key in the keychain of the app.
    public static func importPfx(_ pfx: [UInt8], _ password: String) throws -> X509Certificate {
        #if os(macOS)
        if #available(macOS 15, *) { return try importPfx(pfx, password, keychain: nil, inMemory: true) }
        return try importPfxThroughKeychain(pfx, password)
        #else
        return try importPfx(pfx, password, keychain: nil, inMemory: false)
        #endif
    }

    #if os(macOS)
    /// The way macOS 14 takes; the macOS 15 runners take it too in a test.
    static func importPfxThroughKeychain(_ pfx: [UInt8], _ password: String) throws -> X509Certificate {
        guard let temporary = TemporaryKeychain(password) else { throw SignatureCryptoException(message: "The PFX file could not be read (no keychain).") }
        let imported = try importPfx(pfx, password, keychain: temporary.keychain, inMemory: false)
        imported.keyHolder = temporary
        return imported
    }
    #endif

    private static func importPfx(_ pfx: [UInt8], _ password: String, keychain: AnyObject?, inMemory: Bool) throws -> X509Certificate {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        if inMemory, #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        if let keychain { options[kSecImportExportKeychain as String] = keychain }
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
        #if !os(macOS)
        parsed.keyHolder = ImportedIdentity(identity)
        #endif
        return parsed
    }

    // A comma or a quote in a name would end its attribute early.
    private static func escape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

#if !os(macOS)
/// SecPKCS12Import stores the identity in the app's keychain on iOS; this takes it out again once the certificate is let go,
/// so signing with a .p12 leaves no key behind.
final class ImportedIdentity: KeyHolder {
    private let identity: SecIdentity

    init(_ identity: SecIdentity) {
        self.identity = identity
    }

    func prepare() {}

    deinit {
        SecItemDelete([kSecValueRef as String: identity] as CFDictionary)
    }
}
#endif

#if os(macOS)
/// A keychain file in the temporary folder that lives as long as the key in it is used. The name carries the number
/// of the process, so that the next one can remove what a crash left.
final class TemporaryKeychain: KeyHolder {
    private static let prefix = "lazypdf-"
    let path = NSTemporaryDirectory() + TemporaryKeychain.prefix + "\(ProcessInfo.processInfo.processIdentifier)-" + UUID().uuidString + ".keychain"
    let keychain: SecKeychain
    private let secret: [UInt8]

    init?(_ password: String) {
        Self.removeStale()
        var created: SecKeychain?
        let secret = Array(password.utf8)
        guard SecKeychainCreate(path, UInt32(secret.count), secret, false, nil, &created) == errSecSuccess, let created else { return nil }
        self.secret = secret
        keychain = created
    }

    /// The system locks a keychain after five minutes and on sleep, and unlocking it asks for a password nobody knows, so
    /// the certificate unlocks it each time its key is asked for.
    func prepare() {
        SecKeychainUnlock(keychain, UInt32(secret.count), secret, true)
    }

    deinit {
        SecKeychainDelete(keychain)
        if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Removes the keychain files of processes that are gone.
    static func removeStale() {
        let folder = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix(prefix) && name.contains(".keychain") {
            // lazypdf-<process number>-<UUID>.keychain: a name of any other shape is not ours to remove.
            let rest = name.dropFirst(prefix.count)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let tail = rest.dropFirst(digits.count)
            guard let pid = Int32(digits), tail.hasPrefix("-"), let end = tail.range(of: ".keychain"),
                  UUID(uuidString: String(tail[tail.index(after: tail.startIndex)..<end.lowerBound])) != nil,
                  pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(atPath: folder + name)
        }
    }
}
#endif
#endif
