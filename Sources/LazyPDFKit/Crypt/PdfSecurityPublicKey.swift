#if canImport(Security)
import Foundation
import Security

// Twin of windows/LazyPDF.Core/Crypt/PdfSecurityPublicKey.cs: the public-key handler, /Filter /Adobe.PubSec,
// ISO 32000-1 7.6.4 and 7.6.5: SubFilter s3 or s4 (V 1 or 2, RC4, /Recipients in the encryption dictionary), s5
// and s4 with V 4 (crypt filters, /Recipients in the filter), and s5 with V 5. Each recipient is a CMS
// EnvelopedData holding a 20-byte seed and the recipient's 4 permission bytes; the file key is a digest of the
// seed and every EnvelopedData as stored.
//
// The C# has System.Security.Cryptography.Pkcs for the CMS. Here PdfCms.swift reads and writes the structure and
// Security.framework does the one step that needs a key: RSA key transport, PKCS#1 v1.5 or OAEP
// (SecKeyCreateEncryptedData and SecKeyCreateDecryptedData) and ECDH for the elliptic curve recipients of
// PdfCmsAgreement.swift (SecKeyCopyKeyExchangeResult). An RSA entry that is the certificate's own but uses an
// algorithm that is not read is `unsupported`, not a wrong certificate. The file is Apple-only; Linux builds the
// rest of the engine without it.

extension PdfSecurity {
    private static let maxRecipients = 1000
    private static let cryptFilterName = "DefaultCryptFilter"

    /// The handler for an /Adobe.PubSec `encrypt` dictionary (fully resolved), opened with the private key of
    /// `certificate`; nil when the certificate is not among the recipients or has no usable private key.
    /// Throws `PdfReadException`: unsupported for another SubFilter or V, a cipher that does not fit it, an entry
    /// for the certificate sealed with an algorithm that is not read; damaged for no /Recipients.
    public static func openPublicKey(_ encrypt: PdfDictionary, _ certificate: PdfCertificate) throws -> PdfSecurity? {
        let subFilter = (encrypt["SubFilter"] as? PdfName)?.value
        let v = number(encrypt, "V", 0)
        let direct = (subFilter == "adbe.pkcs7.s3" || subFilter == "adbe.pkcs7.s4") && (v == 1 || v == 2)
        let known = direct || (subFilter == "adbe.pkcs7.s4" && v == 4) || (subFilter == "adbe.pkcs7.s5" && (v == 4 || v == 5))
        guard (encrypt["Filter"] as? PdfName)?.value == "Adobe.PubSec", known else {
            throw PdfReadException(.unsupported, "The public-key handler \(subFilter ?? "") with version \(v) is not supported.")
        }

        let (strings, streams, filters) = try readFilters(encrypt, v)
        let embedded = try checkCiphers(encrypt, v, v == 5, strings, streams, filters)
        var filter: PdfDictionary?
        if !direct {
            // Recipients sit in whichever filter the file uses; /StmF, /StrF and /EFF may each be Identity.
            let cf = encrypt["CF"] as? PdfDictionary
            for key in ["StmF", "StrF", "EFF"] {
                if let name = (encrypt[key] as? PdfName)?.value, let found = cf?[name] as? PdfDictionary {
                    filter = found
                    break
                }
            }
            if filter == nil { throw PdfReadException.damaged("The public-key crypt filter is missing.") }
        }
        guard let list = (direct ? encrypt["Recipients"] : filter?["Recipients"]) as? PdfArray else {
            throw PdfReadException.damaged("The public-key handler has no /Recipients.")
        }
        let recipients = list.items.prefix(maxRecipients).compactMap { ($0 as? PdfString)?.bytes }
        let flag = (filter ?? encrypt)["EncryptMetadata"] ?? encrypt["EncryptMetadata"]
        let metadata = v < 4 || (flag as? PdfBoolean)?.value != false
        let length = v == 1 ? 5 : v == 4 ? 16 : min(max(number(encrypt, "Length", 40) / 8, 5), 16)

        guard let identity = PdfCms.identity(ofCertificate: [UInt8](SecCertificateCopyData(certificate.certificate) as Data)) else {
            return nil
        }
        var refused: PdfReadException?
        for stored in recipients {
            let opened: [UInt8]?
            do {
                opened = try unseal(stored, certificate, identity)
            } catch let error as PdfReadException {
                refused = refused ?? error
                continue
            }
            guard let content = opened, content.count == 24 else { continue }
            let key = fileKey(v, length, Array(content[0..<20]), recipients, metadata)
            let high = (UInt32(content[20]) << 24) | (UInt32(content[21]) << 16)
            let p = Int(Int32(bitPattern: high | (UInt32(content[22]) << 8) | UInt32(content[23])))
            return PdfSecurity(dictionary: encrypt, key: key, revision: v == 5 ? 6 : v, permissionBits: p,
                               openedAsOwner: (p & 2) != 0, encryptMetadata: metadata, strings: strings,
                               streams: streams, filters: filters, fill: systemRandom, embedded: embedded,
                               isPublicKey: true)
        }
        if let refused { throw refused }
        return nil
    }

    /// A handler for a new file readable by exactly `recipients`, each with their own permissions.
    /// `PdfCryptStrength.aes256` makes V 5 (s5), `aes128` V 4 (also s5). The seed and the CMS content keys come
    /// from the system generator, so two calls never give the same file. The new handler is an owner:
    /// `openedAsOwner` is true and its permissions are all. Throws `PdfReadException` for a certificate that is
    /// not an RSA one that may encipher or a P-256 or P-384 one that may agree on a key.
    public static func createPublicKey(_ recipients: [PdfRecipient], _ strength: PdfCryptStrength) throws -> PdfSecurity {
        precondition(recipients.count >= 1 && recipients.count <= maxRecipients,
                     "A file has between 1 and \(maxRecipients) recipients.")
        for recipient in recipients where !PdfRecipient.canProtect(recipient.certificate) {
            throw PdfReadException(.unsupported, "This certificate cannot be used to protect a file. Choose a certificate with an RSA or a P-256 or P-384 key.")
        }
        let modern = strength == .aes256
        let v = modern ? 5 : 4
        let keyBytes = modern ? 32 : 16
        let seed = systemRandom(20)

        var stored: [[UInt8]] = []
        for recipient in recipients {
            // Bits 7, 8 and 13 to 32 are reserved and set, as in /P.
            var bits = UInt32(0xFFFFF0C0) | UInt32(truncatingIfNeeded: recipient.permissions.rawValue & PdfPermissions.all.rawValue)
            if recipient.canChangeEncryption { bits |= 2 }
            let content = seed + [UInt8(truncatingIfNeeded: bits >> 24), UInt8(truncatingIfNeeded: bits >> 16),
                                  UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)]
            stored.append(try seal(content, recipient.certificate))
        }

        let filter = PdfDictionary()
        filter.add("Type", PdfName("CryptFilter"))
        filter.add("CFM", PdfName(modern ? "AESV3" : "AESV2"))
        filter.add("AuthEvent", PdfName("DocOpen"))
        filter.add("Length", PdfNumber(keyBytes))
        filter.add("Recipients", PdfArray(stored.map { PdfString(bytes: $0, isHex: true) }))
        filter.add("EncryptMetadata", PdfBoolean(true))
        let cf = PdfDictionary()
        cf.add(cryptFilterName, filter)

        let dictionary = PdfDictionary()
        dictionary.add("Filter", PdfName("Adobe.PubSec"))
        dictionary.add("SubFilter", PdfName("adbe.pkcs7.s5"))
        dictionary.add("V", PdfNumber(v))
        dictionary.add("Length", PdfNumber(keyBytes * 8))
        dictionary.add("CF", cf)
        dictionary.add("StmF", PdfName(cryptFilterName))
        dictionary.add("StrF", PdfName(cryptFilterName))

        let method: Method = modern ? .aes256 : .aes128
        let p = Int(Int32(bitPattern: UInt32(0xFFFFF0C0) | UInt32(truncatingIfNeeded: PdfPermissions.all.rawValue) | 2))
        return PdfSecurity(dictionary: dictionary, key: fileKey(v, keyBytes, seed, stored, true), revision: modern ? 6 : 4,
                           permissionBits: p, openedAsOwner: true, encryptMetadata: true, strings: method,
                           streams: method, filters: [cryptFilterName: method], fill: systemRandom, isPublicKey: true)
    }

    // 7.6.5.3: SHA-1 of seed, recipients and, without metadata encryption, four 0xFF bytes, cut to the key length for V 1 to 4;
    // SHA-256 of the same for V 5.
    private static func fileKey(_ v: Int, _ length: Int, _ seed: [UInt8], _ recipients: [[UInt8]],
                                _ encryptMetadata: Bool) -> [UInt8] {
        var input = seed
        for recipient in recipients { input += recipient }
        if !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
        return v == 5 ? Sha256.hash(input) : Array(Sha1.hash(input).prefix(length))
    }

    /// The bytes inside an EnvelopedData addressed to the certificate, or nil. Throws `unsupported` for an entry
    /// that is the certificate's own but is sealed with an algorithm that is not read.
    private static func unseal(_ stored: [UInt8], _ certificate: PdfCertificate, _ identity: PdfCertificateIdentity) throws -> [UInt8]? {
        guard let privateKey = certificate.privateKey, let envelope = PdfCms.decode(stored) else { return nil }
        for recipient in envelope.recipients where PdfCms.matches(recipient, identity) {
            guard let algorithm = transport(recipient), PdfCms.contentCiphers.contains(envelope.contentAlgorithm) else {
                throw PdfReadException(.unsupported, "The entry for the certificate uses an algorithm that is not supported.")
            }
            guard let wrapped = SecKeyCreateDecryptedData(privateKey, algorithm, Data(recipient.encryptedKey) as CFData, nil) as Data?,
                  let content = PdfCms.decryptContent(envelope, key: [UInt8](wrapped)) else { continue }
            return content
        }
        return PdfCms.openAgreement(envelope) { agreed(privateKey, $0.point) }
    }

    // ECDH of the private key with the originator's ephemeral key; nil for a key that is not on the curve or not an EC one.
    private static func agreed(_ privateKey: SecKey, _ point: [UInt8]) -> [UInt8]? {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let peer = SecKeyCreateWithData(Data(point) as CFData, attributes as CFDictionary, nil),
              let secret = SecKeyCopyKeyExchangeResult(privateKey, .ecdhKeyExchangeStandard, peer, [:] as CFDictionary, nil) as Data?
        else { return nil }
        return [UInt8](secret)
    }

    private static func transport(_ recipient: PdfCmsRecipient) -> SecKeyAlgorithm? {
        switch recipient.algorithm {
        case PdfCms.rsaEncryption:
            return .rsaEncryptionPKCS1
        case PdfCms.rsaesOaep:
            switch recipient.oaepHash ?? "" {
            case PdfCms.sha1: return .rsaEncryptionOAEPSHA1
            case PdfCms.sha224: return .rsaEncryptionOAEPSHA224
            case PdfCms.sha256: return .rsaEncryptionOAEPSHA256
            case PdfCms.sha384: return .rsaEncryptionOAEPSHA384
            case PdfCms.sha512: return .rsaEncryptionOAEPSHA512
            default: return nil
            }
        default:
            return nil
        }
    }

    /// An EnvelopedData of `content` for one certificate: a fresh AES-256 key under the certificate's RSA key, or wrapped
    /// under a key agreed with a fresh ephemeral EC key.
    private static func seal(_ content: [UInt8], _ recipient: PdfCertificate) throws -> [UInt8] {
        guard let publicKey = SecCertificateCopyKey(recipient.certificate),
              let identity = PdfCms.identity(ofCertificate: [UInt8](SecCertificateCopyData(recipient.certificate) as Data))
        else { throw PdfReadException(.unsupported, "Only RSA and elliptic curve certificates can be recipients.") }
        let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any]
        if attributes?[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
           let bits = attributes?[kSecAttrKeySizeInBits] as? Int {
            return try sealToCurve(content, publicKey, bits, identity)
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionPKCS1) else {
            throw PdfReadException(.unsupported, "Only RSA and elliptic curve certificates can be recipients.")
        }
        let contentKey = systemRandom(32), iv = systemRandom(16)
        let encrypted = Aes(key: contentKey).encryptCbc(Aes.padded(content), iv: iv)
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, Data(contentKey) as CFData, nil) as Data? else {
            throw PdfReadException(.unsupported, "The certificate's key cannot encrypt for a recipient.")
        }
        var entry = PdfCmsRecipient(algorithm: PdfCms.rsaEncryption, encryptedKey: [UInt8](wrapped))
        entry.issuer = identity.issuer
        entry.serial = identity.serial
        return PdfCms.encode(recipients: [entry], iv: iv, encryptedContent: encrypted)
    }

    private static func sealToCurve(_ content: [UInt8], _ publicKey: SecKey, _ bits: Int, _ identity: PdfCertificateIdentity) throws -> [UInt8] {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: bits]
        guard bits == 256 || bits == 384,
              let ephemeral = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let point = SecKeyCopyPublicKey(ephemeral).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }),
              let secret = SecKeyCopyKeyExchangeResult(ephemeral, .ecdhKeyExchangeStandard, publicKey, [:] as CFDictionary, nil) as Data?,
              let sealed = PdfCms.sealAgreement(content, identity: identity, curve: bits == 256 ? PdfCms.curveP256 : PdfCms.curveP384,
                                                ephemeralPoint: [UInt8](point), secret: [UInt8](secret),
                                                contentKey: systemRandom(32), iv: systemRandom(16))
        else { throw PdfReadException(.unsupported, "The certificate's key cannot agree on a key for a recipient.") }
        return sealed
    }
}
#endif
