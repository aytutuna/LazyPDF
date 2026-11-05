import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfKeys.cs: the password and key algorithms of the standard security handler
// (ISO 32000-1 7.6.3, ISO 32000-2 7.6.4). Algorithm 2.B and the R 6 key wrapping are from Lazy Scan's PdfEncryption.cs.

enum PdfKeys {
    private static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    private static func littleEndian(_ value: Int) -> [UInt8] {
        let bits = UInt32(truncatingIfNeeded: value)
        return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
    }

    // R 2 to 4

    /// The password cut or filled up to 32 bytes with the standard padding (algorithm 2, step a).
    static func pad(_ password: [UInt8]) -> [UInt8] {
        let length = min(password.count, 32)
        return Array(password.prefix(length)) + padding.prefix(32 - length)
    }

    /// Algorithm 2: the file key from a padded user password.
    static func fileKey(_ paddedUser: [UInt8], _ o: [UInt8], _ p: Int, _ id: [UInt8], _ revision: Int, _ length: Int,
                        _ encryptMetadata: Bool) -> [UInt8] {
        let skipMetadata = revision >= 4 && !encryptMetadata
        var input = Array(paddedUser.prefix(32))
        input += o.prefix(32)
        input += littleEndian(p)
        input += id
        if skipMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
        var hash = Md5.hash(input)
        if revision >= 3 {
            for _ in 0..<50 { hash = Md5.hash(Array(hash.prefix(length))) }
        }
        return Array(hash.prefix(length))
    }

    /// Algorithms 4 and 5: the value /U holds, 32 bytes for R 2; for R 3 and later the first 16 are the check and the rest is filler.
    static func userValue(_ key: [UInt8], _ id: [UInt8], _ revision: Int) -> [UInt8] {
        if revision == 2 { return Rc4.apply(key, padding) }
        return roundsUp(key, Rc4.apply(key, Md5.hash(padding + id)))
    }

    /// Algorithm 6: whether the key is the one /U was made from.
    static func checkUser(_ key: [UInt8], _ u: [UInt8], _ id: [UInt8], _ revision: Int) -> Bool {
        let count = revision == 2 ? 32 : 16
        return userValue(key, id, revision).prefix(count) == u.prefix(count)
    }

    private static func ownerKey(_ owner: [UInt8], _ revision: Int, _ length: Int) -> [UInt8] {
        var hash = Md5.hash(pad(owner))
        if revision >= 3 {
            for _ in 0..<50 { hash = Md5.hash(hash) }
        }
        return Array(hash.prefix(length))
    }

    /// Algorithm 7, first half: the padded user password hidden in /O, recovered with an owner password.
    static func userPasswordFromOwner(_ owner: [UInt8], _ o: [UInt8], _ revision: Int, _ length: Int) -> [UInt8] {
        let key = ownerKey(owner, revision, length)
        let hidden = Array(o.prefix(32))
        return revision == 2 ? Rc4.apply(key, hidden) : roundsDown(key, hidden)
    }

    /// Algorithm 3: /O from the owner and user passwords.
    static func ownerValue(_ owner: [UInt8], _ user: [UInt8], _ revision: Int, _ length: Int) -> [UInt8] {
        let key = ownerKey(owner, revision, length)
        let value = Rc4.apply(key, pad(user))
        return revision == 2 ? value : roundsUp(key, value)
    }

    // RC4 passes 1 to 19 with the key xored by the pass number, for encrypting.
    private static func roundsUp(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var data = data
        for i in 1...19 { data = Rc4.apply(xored(key, i), data) }
        return data
    }

    // The same passes from 19 down to 0, for decrypting what roundsUp made (pass 0 is the plain key).
    private static func roundsDown(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var data = data
        for i in stride(from: 19, through: 0, by: -1) { data = Rc4.apply(xored(key, i), data) }
        return data
    }

    private static func xored(_ key: [UInt8], _ value: Int) -> [UInt8] {
        key.map { $0 ^ UInt8(truncatingIfNeeded: value) }
    }

    // R 5 and 6

    /// The hash of algorithm 2.A: SHA-256 alone for R 5, algorithm 2.B for R 6.
    static func hash(_ revision: Int, _ password: [UInt8], _ salt: [UInt8], _ userKey: [UInt8]) -> [UInt8] {
        if revision == 5 { return Sha256.hash(password + salt + userKey) }
        return hash2B(password, salt, userKey)
    }

    /// Algorithm 2.B of ISO 32000-2: K = SHA-256(password, salt, userKey), then rounds of
    /// E = AES-128-CBC over 64 copies of (password, K, userKey) keyed with K's first 16 bytes and
    /// IV from its next 16, and K = SHA-256, 384 or 512 of E by E's first 16 bytes summed modulo 3.
    /// At least 64 rounds, then on while E's last byte is above the round number minus 32.
    /// `userKey` is the 48-byte /U for the owner password, else empty.
    private static func hash2B(_ password: [UInt8], _ salt: [UInt8], _ userKey: [UInt8]) -> [UInt8] {
        var k = Sha256.hash(password + salt + userKey)
        var e: [UInt8] = []
        var round = 0
        while round < 64 || Int(e.last ?? 0) > round - 32 {
            let unit = password + k + userKey
            var k1: [UInt8] = []
            k1.reserveCapacity(unit.count * 64)
            for _ in 0..<64 { k1.append(contentsOf: unit) }
            e = Aes(key: Array(k.prefix(16))).encryptCbc(k1, iv: Array(k[16..<32]))
            let sum = e.prefix(16).reduce(0) { $0 + Int($1) }
            switch sum % 3 {
            case 0: k = Sha256.hash(e)
            case 1: k = Sha384.hash(e)
            default: k = Sha512.hash(e)
            }
            round += 1
        }
        return Array(k.prefix(32))
    }

    /// Algorithm 2.A: the file key when `password` is the owner's (checked first) or the user's, else nil.
    static func openFileKey(_ revision: Int, _ password: [UInt8], _ o: [UInt8], _ u: [UInt8], _ oe: [UInt8],
                            _ ue: [UInt8]) -> (key: [UInt8]?, asOwner: Bool) {
        let userBytes = Array(u[0..<48])
        if hash(revision, password, Array(o[32..<40]), userBytes) == Array(o[0..<32]) {
            return (unwrapKey(hash(revision, password, Array(o[40..<48]), userBytes), oe), true)
        }
        if hash(revision, password, Array(u[32..<40]), []) == Array(u[0..<32]) {
            return (unwrapKey(hash(revision, password, Array(u[40..<48]), []), ue), false)
        }
        return (nil, false)
    }

    private static func unwrapKey(_ key: [UInt8], _ wrapped: [UInt8]) -> [UInt8] {
        Aes(key: key).decryptCbc(Array(wrapped.prefix(32)), iv: [UInt8](repeating: 0, count: 16))
    }

    /// /UE and /OE: the file key under a key made from a password, zero IV and no padding.
    static func wrapKey(_ key: [UInt8], _ fileKey: [UInt8]) -> [UInt8] {
        Aes(key: key).encryptCbc(fileKey, iv: [UInt8](repeating: 0, count: 16))
    }

    /// Algorithm 2.A step on /Perms: decrypts it and compares /P, the metadata flag and the "adb" marker.
    static func permsMatch(_ fileKey: [UInt8], _ perms: [UInt8], _ p: Int, _ encryptMetadata: Bool) -> Bool {
        if perms.count < 16 { return false }
        let block = Aes(key: fileKey).decryptEcb(Array(perms.prefix(16)))
        let b0 = UInt32(block[0]), b1 = UInt32(block[1]), b2 = UInt32(block[2]), b3 = UInt32(block[3])
        let stored = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        return Int(Int32(bitPattern: stored)) == p
            && block[8] == (encryptMetadata ? UInt8(ascii: "T") : UInt8(ascii: "F"))
            && Array(block[9..<12]) == Array("adb".utf8)
    }

    /// Algorithm 10: /Perms, the permissions and the metadata flag under the file key, so a changed /P is noticed.
    static func perms(_ fileKey: [UInt8], _ p: Int, _ filler: [UInt8]) -> [UInt8] {
        var block = littleEndian(p) + [0xFF, 0xFF, 0xFF, 0xFF]
        block += Array("Tadb".utf8)
        block += filler.prefix(4)
        return Aes(key: fileKey).encryptEcb(block)
    }
}
