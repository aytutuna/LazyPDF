import Foundation

// No C# twin: ExportPkcs12 with Pkcs12ExportPbeParameters.Pbes2Aes256Sha256 (RFC 7292, RFC 8018). SecItemExport can
// only write the old pbeWithSHAAnd3-KeyTripleDES and 40 bit RC2 protection, so the file is written here: the
// certificate and the PKCS#8 key each in a bag protected by PBES2 (PBKDF2 with HMAC-SHA256, AES-256-CBC), and a
// HMAC-SHA256 over the whole. The iteration count is the 2000 that .NET writes: its loader refuses more than 300 000,
// so a count chosen higher would give files the Windows app cannot open. Nothing here needs Security.framework.

enum Pkcs12Writer {
    private static let iterations = 2000
    private static let pbes2 = "1.2.840.113549.1.5.13"
    private static let pbkdf2 = "1.2.840.113549.1.5.12"
    private static let hmacSha256 = "1.2.840.113549.2.9"
    private static let aes256Cbc = "2.16.840.1.101.3.4.1.42"
    private static let sha256 = "2.16.840.1.101.3.4.2.1"
    private static let keyBag = "1.2.840.113549.1.12.10.1.2"
    private static let certificateBag = "1.2.840.113549.1.12.10.1.3"
    private static let x509Certificate = "1.2.840.113549.1.9.22.1"
    private static let localKeyId = "1.2.840.113549.1.9.21"
    private static let encryptedData = "1.2.840.113549.1.7.6"

    /// The certificate and its key, an RSA key as its PKCS#1 form and a P-256 key as the X9.63 point and scalar that
    /// Security.framework gives for it, in a PFX file protected by `password`.
    static func write(_ certificate: X509Certificate, _ key: [UInt8], password: String, random: (Int) -> [UInt8] = SignatureCrypto.randomBytes) throws -> [UInt8] {
        guard let pkcs8 = privateKeyInfo(certificate, key) else { throw SignatureCryptoException(message: "The key is of a kind a PFX file is not written for.") }
        let id = Sha1.hash(certificate.rawData)
        let attributes = DerWriter.set([DerWriter.sequence([DerWriter.oid(localKeyId), DerWriter.set([DerWriter.octetString(id)])])])

        let certificateSafe = DerWriter.sequence([DerWriter.sequence([
            DerWriter.oid(certificateBag),
            DerWriter.context(0, constructed: true, DerWriter.sequence([
                DerWriter.oid(x509Certificate),
                DerWriter.context(0, constructed: true, DerWriter.octetString(certificate.rawData)),
            ])),
            attributes,
        ])])
        let (certificateAlgorithm, certificateCipher) = try protect(certificateSafe, password, random)
        let encrypted = DerWriter.sequence([
            DerWriter.integer(0),
            DerWriter.sequence([DerWriter.oid(Oids.data), certificateAlgorithm, DerWriter.node(0x80, certificateCipher)]),
        ])
        let wrappedEncrypted = DerWriter.sequence([DerWriter.oid(encryptedData), DerWriter.context(0, constructed: true, encrypted)])

        let (keyAlgorithm, keyCipher) = try protect(pkcs8, password, random)
        let keySafe = DerWriter.sequence([DerWriter.sequence([
            DerWriter.oid(keyBag),
            DerWriter.context(0, constructed: true, DerWriter.sequence([keyAlgorithm, DerWriter.octetString(keyCipher)])),
            attributes,
        ])])
        let wrappedKeys = DerWriter.sequence([DerWriter.oid(Oids.data), DerWriter.context(0, constructed: true, DerWriter.octetString(keySafe))])

        let safe = DerWriter.sequence([wrappedEncrypted, wrappedKeys])
        let macSalt = random(16)
        let macKey = try derivedMacKey(password, macSalt)
        let mac = hmac(macKey, safe)
        return DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.sequence([DerWriter.oid(Oids.data), DerWriter.context(0, constructed: true, DerWriter.octetString(safe))]),
            DerWriter.sequence([
                DerWriter.sequence([CmsBuilder.algorithmIdentifier(sha256, withNull: false), DerWriter.octetString(mac)]),
                DerWriter.octetString(macSalt),
                DerWriter.integer(AsnInteger(iterations)),
            ]),
        ])
    }

    // PrivateKeyInfo (RFC 5208) of a key as Security.framework hands it out.
    private static func privateKeyInfo(_ certificate: X509Certificate, _ key: [UInt8]) -> [UInt8]? {
        switch SignatureCrypto.keyKind(certificate) {
        case .rsa:
            return DerWriter.sequence([DerWriter.integer(0), CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true), DerWriter.octetString(key)])
        case .ec:
            guard key.count == 97, key[0] == 4 else { return nil }
            let scalar = Array(key[65...]), point = Array(key[0..<65])
            let ecKey = DerWriter.sequence([DerWriter.integer(1), DerWriter.octetString(scalar), DerWriter.context(1, constructed: true, DerWriter.bitString(point))])
            let algorithm = DerWriter.sequence([DerWriter.oid(Oids.ecPublicKey), DerWriter.oid("1.2.840.10045.3.1.7")])
            return DerWriter.sequence([DerWriter.integer(0), algorithm, DerWriter.octetString(ecKey)])
        case nil:
            return nil
        }
    }

    // PBES2 of RFC 8018: the AlgorithmIdentifier that says how, and the data encrypted.
    private static func protect(_ data: [UInt8], _ password: String, _ random: (Int) -> [UInt8]) throws -> ([UInt8], [UInt8]) {
        let salt = random(16), iv = random(16)
        guard let key = pbkdf2(Array(password.utf8), salt) else { throw SignatureCryptoException(message: "The key could not be derived.") }
        let cipher = Aes(key: key).encryptCbc(Aes.padded(data), iv: iv)
        let derivation = DerWriter.sequence([
            DerWriter.oid(pbkdf2),
            DerWriter.sequence([
                DerWriter.octetString(salt),
                DerWriter.integer(AsnInteger(iterations)),
                CmsBuilder.algorithmIdentifier(hmacSha256, withNull: true),
            ]),
        ])
        let scheme = DerWriter.sequence([DerWriter.oid(aes256Cbc), DerWriter.octetString(iv)])
        return (DerWriter.sequence([DerWriter.oid(pbes2), DerWriter.sequence([derivation, scheme])]), cipher)
    }

    // PBKDF2 of RFC 8018 with HMAC-SHA256, for one block of 32 bytes.
    private static func pbkdf2(_ password: [UInt8], _ salt: [UInt8]) -> [UInt8]? {
        var u = hmac(password, salt + [0, 0, 0, 1])
        var block = u
        for _ in 1..<iterations {
            u = hmac(password, u)
            for i in 0..<block.count { block[i] ^= u[i] }
        }
        return block
    }

    // The key of the MAC by RFC 7292 appendix B.2 with SHA-256: the password as a BMPString and the salt are
    // repeated to whole blocks of 64 bytes, and the hash of the id byte 3 and both is hashed again for each round.
    private static func derivedMacKey(_ password: String, _ salt: [UInt8]) throws -> [UInt8] {
        var bmp: [UInt8] = []
        for unit in password.utf16 { bmp += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        bmp += [0, 0]
        func fill(_ bytes: [UInt8]) -> [UInt8] {
            let blocks = (bytes.count + 63) / 64
            return (0..<blocks * 64).map { bytes[$0 % bytes.count] }
        }
        var digest = sha(([UInt8](repeating: 3, count: 64)) + fill(salt) + fill(bmp))
        for _ in 1..<iterations { digest = sha(digest) }
        return digest
    }

    private static func sha(_ data: [UInt8]) -> [UInt8] { Sha256.hash(data) }

    private static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? Sha256.hash(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        return Sha256.hash(block.map { $0 ^ 0x5C } + Sha256.hash(block.map { $0 ^ 0x36 } + data))
    }
}
