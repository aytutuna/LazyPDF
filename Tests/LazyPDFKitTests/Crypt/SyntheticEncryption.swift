import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Crypt/SyntheticEncryption.cs: /Encrypt dictionaries made straight from the
// algorithms of ISO 32000-1 7.6.3 and ISO 32000-2 7.6.4 with fixed inputs, to check the reader against a second
// reading of the spec. R 6 borrows the library's hash; the pypdf fixtures vouch for it. Hex and SeededRandom stand
// in for Convert.FromHexString and System.Random.

struct BuiltEncryption {
    let dictionary: PdfDictionary
    let fileKey: [UInt8]
}

enum Hex {
    static func bytes(_ text: String) -> [UInt8] {
        let digits = Array(text.utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap {
            UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)
        }
    }

    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

/// SplitMix64: the same bytes for the same seed on every platform.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }
}

enum SyntheticEncryption {
    static let id = Hex.bytes("0123456789ABCDEF0123456789ABCDEF")

    private static let padding = Hex.bytes("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")

    static func legacy(_ v: Int, _ r: Int, _ bits: Int, _ user: String, _ owner: String, p: Int = -4,
                       encryptMetadata: Bool = true, cfm: String? = nil, strF: String = "StdCF",
                       stmF: String = "StdCF") -> BuiltEncryption {
        let n = r == 2 ? 5 : r == 4 ? 16 : bits / 8
        let userPad = pad(user)

        var ownerHash = Md5.hash(pad(owner))
        if r >= 3 { for _ in 0..<50 { ownerHash = Md5.hash(ownerHash) } }
        let ownerKey = Array(ownerHash.prefix(n))
        var o = Rc4.apply(ownerKey, userPad)
        if r >= 3 { for i in 1...19 { o = Rc4.apply(xor(ownerKey, i), o) } }

        var input = userPad + o
        let pBits = UInt32(truncatingIfNeeded: p)
        input += [UInt8(truncatingIfNeeded: pBits), UInt8(truncatingIfNeeded: pBits >> 8),
                  UInt8(truncatingIfNeeded: pBits >> 16), UInt8(truncatingIfNeeded: pBits >> 24)]
        input += id
        if r >= 4 && !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
        var hash = Md5.hash(input)
        if r >= 3 { for _ in 0..<50 { hash = Md5.hash(Array(hash.prefix(n))) } }
        let key = Array(hash.prefix(n))

        var u: [UInt8]
        if r == 2 {
            u = Rc4.apply(key, padding)
        } else {
            u = Rc4.apply(key, Md5.hash(padding + id))
            for i in 1...19 { u = Rc4.apply(xor(key, i), u) }
            u += [UInt8](repeating: 0, count: 16)
        }

        let dictionary = PdfDictionary()
        dictionary.add("Filter", PdfName("Standard"))
        dictionary.add("V", PdfNumber(v))
        dictionary.add("R", PdfNumber(r))
        if v >= 2 { dictionary.add("Length", PdfNumber(bits)) }
        dictionary.add("P", PdfNumber(p))
        dictionary.add("O", PdfString(bytes: o, isHex: true))
        dictionary.add("U", PdfString(bytes: u, isHex: true))
        if v == 4 {
            let std = PdfDictionary()
            std.add("CFM", PdfName(cfm ?? ""))
            let rc4 = PdfDictionary()
            rc4.add("CFM", PdfName("V2"))
            let cf = PdfDictionary()
            cf.add("StdCF", std)
            cf.add("Rc4CF", rc4)
            dictionary.add("CF", cf)
            dictionary.add("StmF", PdfName(stmF))
            dictionary.add("StrF", PdfName(strF))
            if !encryptMetadata { dictionary.add("EncryptMetadata", PdfBoolean(false)) }
        }
        return BuiltEncryption(dictionary: dictionary, fileKey: key)
    }

    static func modern(_ r: Int, _ user: String, _ owner: String, p: Int = -4) -> BuiltEncryption {
        let fileKey = (1...32).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let userPw = Array(user.utf8), ownerPw = Array(owner.utf8)
        let uValidation = Array("uvalid01".utf8), uKeySalt = Array("ukeysalt".utf8)
        let oValidation = Array("ovalid01".utf8), oKeySalt = Array("okeysalt".utf8)

        let u = hash(r, userPw, uValidation, []) + uValidation + uKeySalt
        let ue = wrap(hash(r, userPw, uKeySalt, []), fileKey)
        let o = hash(r, ownerPw, oValidation, u) + oValidation + oKeySalt
        let oe = wrap(hash(r, ownerPw, oKeySalt, u), fileKey)

        let std = PdfDictionary()
        std.add("CFM", PdfName("AESV3"))
        let cf = PdfDictionary()
        cf.add("StdCF", std)
        let dictionary = PdfDictionary()
        dictionary.add("Filter", PdfName("Standard"))
        dictionary.add("V", PdfNumber(5))
        dictionary.add("R", PdfNumber(r))
        dictionary.add("Length", PdfNumber(256))
        dictionary.add("P", PdfNumber(p))
        dictionary.add("CF", cf)
        dictionary.add("StmF", PdfName("StdCF"))
        dictionary.add("StrF", PdfName("StdCF"))
        dictionary.add("O", PdfString(bytes: o, isHex: true))
        dictionary.add("U", PdfString(bytes: u, isHex: true))
        dictionary.add("OE", PdfString(bytes: oe, isHex: true))
        dictionary.add("UE", PdfString(bytes: ue, isHex: true))
        return BuiltEncryption(dictionary: dictionary, fileKey: fileKey)
    }

    /// What a writer stores for an RC4 object (algorithm 1).
    static func storeRc4(_ fileKey: [UInt8], _ number: Int, _ generation: Int, _ plain: [UInt8]) -> [UInt8] {
        Rc4.apply(objectKey(fileKey, number, generation, false), plain)
    }

    /// What a writer stores for an AES-128 object: the IV, then the PKCS#7 padded cipher text.
    static func storeAes128(_ fileKey: [UInt8], _ number: Int, _ generation: Int, _ plain: [UInt8]) -> [UInt8] {
        storeAes(objectKey(fileKey, number, generation, true), plain)
    }

    static func storeAes256(_ fileKey: [UInt8], _ plain: [UInt8]) -> [UInt8] {
        storeAes(fileKey, plain)
    }

    private static func storeAes(_ key: [UInt8], _ plain: [UInt8]) -> [UInt8] {
        let iv = (0..<16).map { UInt8(200 - $0) }
        return iv + Aes(key: key).encryptCbc(Aes.padded(plain), iv: iv)
    }

    private static func objectKey(_ fileKey: [UInt8], _ number: Int, _ generation: Int, _ aes: Bool) -> [UInt8] {
        var input = fileKey
        input += [UInt8(truncatingIfNeeded: number), UInt8(truncatingIfNeeded: number >> 8),
                  UInt8(truncatingIfNeeded: number >> 16), UInt8(truncatingIfNeeded: generation),
                  UInt8(truncatingIfNeeded: generation >> 8)]
        if aes { input += Array("sAlT".utf8) }
        return Array(Md5.hash(input).prefix(min(fileKey.count + 5, 16)))
    }

    private static func hash(_ r: Int, _ password: [UInt8], _ salt: [UInt8], _ userKey: [UInt8]) -> [UInt8] {
        r == 5 ? Sha256.hash(password + salt + userKey) : PdfKeys.hash(6, password, salt, userKey)
    }

    private static func wrap(_ key: [UInt8], _ fileKey: [UInt8]) -> [UInt8] {
        Aes(key: key).encryptCbc(fileKey, iv: [UInt8](repeating: 0, count: 16))
    }

    private static func pad(_ password: String) -> [UInt8] {
        Array((Latin1.bytes(password) + padding).prefix(32))
    }

    private static func xor(_ key: [UInt8], _ value: Int) -> [UInt8] {
        key.map { $0 ^ UInt8(truncatingIfNeeded: value) }
    }
}
