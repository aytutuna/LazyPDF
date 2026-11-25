import Foundation
#if canImport(Security)
import Security
#endif

// No C# twin: the key operations System.Security.Cryptography does for the C# (RSA and ECDSA sign and verify, hashes).
// They go through Security.framework on Apple platforms. Without it every check answers "does not verify" and signing
// throws, so a build on Linux can read and judge the structure of a file but never calls a signature good.

enum SignatureKeyKind {
    case rsa
    case ec
}

public struct SignatureCryptoException: Error {
    public let message: String
}

enum SignatureCrypto {
    static func hash(_ algorithm: HashAlgorithmName, _ data: [UInt8]) -> [UInt8] {
        switch algorithm {
        case .sha1: return Sha1.hash(data)
        case .sha256: return Sha256.hash(data)
        case .sha384: return Sha384.hash(data)
        case .sha512: return Sha512.hash(data)
        }
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess { return bytes }
        #endif
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    static func keyKind(_ certificate: X509Certificate) -> SignatureKeyKind? {
        switch certificate.publicKeyAlgorithm {
        case Oids.rsaEncryption: return .rsa
        case Oids.ecPublicKey: return .ec
        default: return nil
        }
    }

    /// nil when the certificate holds no key of that kind or the platform cannot check it.
    static func verifyRsa(_ certificate: X509Certificate, _ hash: [UInt8], _ algorithm: HashAlgorithmName, _ signature: [UInt8], pss: Bool) -> Bool? {
        #if canImport(Security)
        guard keyKind(certificate) == .rsa, let key = publicKey(certificate, rsa: true) else { return nil }
        let method: SecKeyAlgorithm
        switch (algorithm, pss) {
        case (.sha1, false): method = .rsaSignatureDigestPKCS1v15SHA1
        case (.sha256, false): method = .rsaSignatureDigestPKCS1v15SHA256
        case (.sha384, false): method = .rsaSignatureDigestPKCS1v15SHA384
        case (.sha512, false): method = .rsaSignatureDigestPKCS1v15SHA512
        case (.sha1, true): method = .rsaSignatureDigestPSSSHA1
        case (.sha256, true): method = .rsaSignatureDigestPSSSHA256
        case (.sha384, true): method = .rsaSignatureDigestPSSSHA384
        case (.sha512, true): method = .rsaSignatureDigestPSSSHA512
        }
        return SecKeyVerifySignature(key, method, Data(hash) as CFData, Data(signature) as CFData, nil)
        #else
        return nil
        #endif
    }

    /// `signature` is the DER SEQUENCE of r and s.
    static func verifyEcdsa(_ certificate: X509Certificate, _ hash: [UInt8], _ signature: [UInt8]) -> Bool? {
        #if canImport(Security)
        guard keyKind(certificate) == .ec, let key = publicKey(certificate, rsa: false) else { return nil }
        return SecKeyVerifySignature(key, .ecdsaSignatureDigestX962, Data(hash) as CFData, Data(signature) as CFData, nil)
        #else
        return nil
        #endif
    }

    #if canImport(Security)
    private static func publicKey(_ certificate: X509Certificate, rsa: Bool) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(Data(certificate.encodedKeyValue) as CFData, attributes as CFDictionary, nil)
    }

    /// An RSA PKCS#1 v1.5 signature over the digest, or an ECDSA signature as a DER SEQUENCE.
    static func sign(_ key: SecKey, _ hash: [UInt8], _ algorithm: HashAlgorithmName, ec: Bool) throws -> [UInt8] {
        let method: SecKeyAlgorithm
        if ec {
            method = .ecdsaSignatureDigestX962
        } else {
            switch algorithm {
            case .sha1: method = .rsaSignatureDigestPKCS1v15SHA1
            case .sha256: method = .rsaSignatureDigestPKCS1v15SHA256
            case .sha384: method = .rsaSignatureDigestPKCS1v15SHA384
            case .sha512: method = .rsaSignatureDigestPKCS1v15SHA512
            }
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, method, Data(hash) as CFData, &error) else {
            throw SignatureCryptoException(message: "The key could not sign.")
        }
        return [UInt8](signature as Data)
    }

    /// A new RSA key of `bits` bits that is not kept in a keychain.
    static func newRsaKey(_ bits: Int) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SignatureCryptoException(message: "The key could not be made.")
        }
        return key
    }

    /// A new P-256 key that is not kept in a keychain.
    static func newEcKey() throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SignatureCryptoException(message: "The key could not be made.")
        }
        return key
    }

    /// The public half in the form a certificate carries: PKCS#1 for RSA, the uncompressed point for EC.
    static func publicKeyBytes(_ key: SecKey) throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key), let data = SecKeyCopyExternalRepresentation(pub, nil) else {
            throw SignatureCryptoException(message: "The public key could not be read.")
        }
        return [UInt8](data as Data)
    }
    #endif
}
