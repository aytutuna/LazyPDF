import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfSecurityCreate.cs: the handler of a new file, R 6 or R 4.

extension PdfSecurity {
    /// A handler for a new file. An empty `ownerPassword` becomes random bytes nobody knows, so the
    /// permissions bind everyone who opens the file. The keys, salts and IVs come from `random` (nil: the
    /// system's cryptographic generator); a seeded one is for tests. `firstId` is the first string of the
    /// trailer's /ID, which `PdfCryptStrength.aes128` mixes into the key.
    public static func create(userPassword: String, ownerPassword: String, permissions: PdfPermissions,
                              strength: PdfCryptStrength, firstId: [UInt8],
                              random: (any RandomNumberGenerator)? = nil) -> PdfSecurity {
        let fill: (Int) -> [UInt8]
        if var generator = random {
            fill = { count in (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) } }
        } else {
            fill = systemRandom
        }
        // Bits 7, 8 and 13 to 32 are reserved and must be set (ISO 32000-1 7.6.3.2).
        let bits = UInt32(0xFFFFF0C0) | UInt32(truncatingIfNeeded: permissions.rawValue & PdfPermissions.all.rawValue)
        let p = Int(Int32(bitPattern: bits))
        return strength == .aes128
            ? createAes128(userPassword, ownerPassword, p, firstId, fill)
            : createAes256(userPassword, ownerPassword, p, fill)
    }

    private static func createAes256(_ userPassword: String, _ ownerPassword: String, _ p: Int,
                                     _ fill: @escaping (Int) -> [UInt8]) -> PdfSecurity {
        let user = PdfPasswords.prepare(userPassword)
        var owner = PdfPasswords.prepare(ownerPassword)
        let fileKey = fill(32)
        let userValidation = fill(8), userKeySalt = fill(8)
        let ownerValidation = fill(8), ownerKeySalt = fill(8)
        if owner.isEmpty { owner = fill(32) }

        let u = PdfKeys.hash(6, user, userValidation, []) + userValidation + userKeySalt
        let ue = PdfKeys.wrapKey(PdfKeys.hash(6, user, userKeySalt, []), fileKey)
        // The owner values are hashed together with the whole of /U.
        let o = PdfKeys.hash(6, owner, ownerValidation, u) + ownerValidation + ownerKeySalt
        let oe = PdfKeys.wrapKey(PdfKeys.hash(6, owner, ownerKeySalt, u), fileKey)
        let perms = PdfKeys.perms(fileKey, p, fill(4))

        let dictionary = standard(5, 6, 256, p, o, u, "AESV3", 32)
        dictionary.add("OE", PdfString(bytes: oe, isHex: true))
        dictionary.add("UE", PdfString(bytes: ue, isHex: true))
        dictionary.add("Perms", PdfString(bytes: perms, isHex: true))
        dictionary.add("EncryptMetadata", PdfBoolean(true))
        return PdfSecurity(dictionary: dictionary, key: fileKey, revision: 6, permissionBits: p, openedAsOwner: true,
                           encryptMetadata: true, strings: .aes256, streams: .aes256, filters: ["StdCF": .aes256],
                           fill: fill)
    }

    private static func createAes128(_ userPassword: String, _ ownerPassword: String, _ p: Int, _ id: [UInt8],
                                     _ fill: @escaping (Int) -> [UInt8]) -> PdfSecurity {
        let user = PdfPasswords.legacy(userPassword)
        var owner = PdfPasswords.legacy(ownerPassword)
        if owner.isEmpty { owner = fill(16) }

        let o = PdfKeys.ownerValue(owner, user, 4, 16)
        let key = PdfKeys.fileKey(PdfKeys.pad(user), o, p, id, 4, 16, true)
        // Only the first 16 bytes of /U are checked; the readers fill the rest with anything.
        let u = PdfKeys.userValue(key, id, 4) + [UInt8](repeating: 0, count: 16)

        let dictionary = standard(4, 4, 128, p, o, u, "AESV2", 16)
        return PdfSecurity(dictionary: dictionary, key: key, revision: 4, permissionBits: p, openedAsOwner: true,
                           encryptMetadata: true, strings: .aes128, streams: .aes128, filters: ["StdCF": .aes128],
                           fill: fill)
    }

    private static func standard(_ v: Int, _ r: Int, _ bits: Int, _ p: Int, _ o: [UInt8], _ u: [UInt8],
                                 _ method: String, _ keyBytes: Int) -> PdfDictionary {
        let filter = PdfDictionary()
        filter.add("CFM", PdfName(method))
        filter.add("AuthEvent", PdfName("DocOpen"))
        filter.add("Length", PdfNumber(keyBytes))
        let cf = PdfDictionary()
        cf.add("StdCF", filter)

        let dictionary = PdfDictionary()
        dictionary.add("Filter", PdfName("Standard"))
        dictionary.add("V", PdfNumber(v))
        dictionary.add("R", PdfNumber(r))
        dictionary.add("Length", PdfNumber(bits))
        dictionary.add("CF", cf)
        dictionary.add("StmF", PdfName("StdCF"))
        dictionary.add("StrF", PdfName("StdCF"))
        dictionary.add("O", PdfString(bytes: o, isHex: true))
        dictionary.add("U", PdfString(bytes: u, isHex: true))
        dictionary.add("P", PdfNumber(p))
        return dictionary
    }
}
