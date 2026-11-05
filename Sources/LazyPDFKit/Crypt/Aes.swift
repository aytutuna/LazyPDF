import Foundation

// AES with 128, 192 or 256 bit keys (FIPS 197), in CBC and ECB mode without padding, and PKCS#7 padding apart.
// The C# gets these from System.Security.Cryptography.Aes; here they are written out so the engine needs
// Foundation alone and gives the same bytes on every platform. Table driven, one word per column.

private struct AesTables {
    let sbox: [UInt8]
    let inverseSbox: [UInt8]
    let encrypt: [UInt32]
    let decrypt: [UInt32]
}

private func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
    var result: UInt8 = 0
    var x = a
    var y = b
    while y != 0 {
        if y & 1 != 0 { result ^= x }
        x = (x << 1) ^ (x & 0x80 != 0 ? 0x1B : 0)
        y >>= 1
    }
    return result
}

private func rotateByte(_ x: UInt8, _ n: UInt8) -> UInt8 {
    (x << n) | (x >> (8 - n))
}

private func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
}

private let tables: AesTables = {
    var sbox = [UInt8](repeating: 0, count: 256)
    var p: UInt8 = 1
    var q: UInt8 = 1
    // p walks the multiplicative group by 3 and q by its inverse, so q is p's inverse.
    repeat {
        p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1B : 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        if q & 0x80 != 0 { q ^= 0x09 }
        let affine = q ^ rotateByte(q, 1) ^ rotateByte(q, 2) ^ rotateByte(q, 3) ^ rotateByte(q, 4)
        sbox[Int(p)] = affine ^ 0x63
    } while p != 1
    sbox[0] = 0x63
    var inverse = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { inverse[Int(sbox[i])] = UInt8(i) }
    var encrypt = [UInt32](repeating: 0, count: 256)
    var decrypt = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        let s = sbox[i]
        let high = (UInt32(multiply(s, 2)) << 24) | (UInt32(s) << 16)
        encrypt[i] = high | (UInt32(s) << 8) | UInt32(multiply(s, 3))
        let t = inverse[i]
        let upper = (UInt32(multiply(t, 14)) << 24) | (UInt32(multiply(t, 9)) << 16)
        decrypt[i] = upper | (UInt32(multiply(t, 13)) << 8) | UInt32(multiply(t, 11))
    }
    return AesTables(sbox: sbox, inverseSbox: inverse, encrypt: encrypt, decrypt: decrypt)
}()

struct Aes {
    private typealias Block = (UInt32, UInt32, UInt32, UInt32)

    private let sbox: [UInt8]
    private let inverseSbox: [UInt8]
    private let encryptTable: [UInt32]
    private let decryptTable: [UInt32]
    private let rounds: Int
    private let encryptKeys: [UInt32]
    private let decryptKeys: [UInt32]

    /// 16, 24 or 32 bytes.
    init(key: [UInt8]) {
        precondition(key.count == 16 || key.count == 24 || key.count == 32, "An AES key is 16, 24 or 32 bytes.")
        sbox = tables.sbox
        inverseSbox = tables.inverseSbox
        encryptTable = tables.encrypt
        decryptTable = tables.decrypt
        let nk = key.count / 4
        let rounds = nk + 6
        self.rounds = rounds
        var words = [UInt32](repeating: 0, count: 4 * (rounds + 1))
        for i in 0..<nk { words[i] = Aes.load(key, 4 * i) }
        var rcon: UInt8 = 1
        for i in nk..<words.count {
            var t = words[i - 1]
            if i % nk == 0 {
                t = Aes.substituted(tables.sbox, rotateRight(t, 24)) ^ (UInt32(rcon) << 24)
                rcon = (rcon << 1) ^ (rcon & 0x80 != 0 ? 0x1B : 0)
            } else if nk > 6 && i % nk == 4 {
                t = Aes.substituted(tables.sbox, t)
            }
            words[i] = words[i - nk] ^ t
        }
        encryptKeys = words
        // The equivalent inverse cipher: the round keys in reverse order, the middle ones mixed.
        var reversed = [UInt32](repeating: 0, count: words.count)
        for i in 0...rounds {
            for j in 0..<4 {
                var v = words[4 * (rounds - i) + j]
                if i > 0 && i < rounds {
                    let s = Aes.substituted(tables.sbox, v)
                    v = Aes.mixed(tables.decrypt, s >> 24, (s >> 16) & 0xFF, (s >> 8) & 0xFF, s & 0xFF)
                }
                reversed[4 * i + j] = v
            }
        }
        decryptKeys = reversed
    }

    func encryptCbc(_ data: [UInt8], iv: [UInt8]) -> [UInt8] {
        precondition(data.count % 16 == 0 && iv.count == 16, "CBC works on whole blocks with a 16 byte IV.")
        var output = [UInt8](repeating: 0, count: data.count)
        var chain: Block = (Aes.load(iv, 0), Aes.load(iv, 4), Aes.load(iv, 8), Aes.load(iv, 12))
        var offset = 0
        while offset < data.count {
            let plain: Block = (Aes.load(data, offset) ^ chain.0, Aes.load(data, offset + 4) ^ chain.1,
                                Aes.load(data, offset + 8) ^ chain.2, Aes.load(data, offset + 12) ^ chain.3)
            chain = encrypt(plain)
            Aes.store(chain, &output, offset)
            offset += 16
        }
        return output
    }

    func decryptCbc(_ data: [UInt8], iv: [UInt8]) -> [UInt8] {
        precondition(data.count % 16 == 0 && iv.count == 16, "CBC works on whole blocks with a 16 byte IV.")
        var output = [UInt8](repeating: 0, count: data.count)
        var chain: Block = (Aes.load(iv, 0), Aes.load(iv, 4), Aes.load(iv, 8), Aes.load(iv, 12))
        var offset = 0
        while offset < data.count {
            let cipher: Block = (Aes.load(data, offset), Aes.load(data, offset + 4),
                                 Aes.load(data, offset + 8), Aes.load(data, offset + 12))
            let plain = decrypt(cipher)
            Aes.store((plain.0 ^ chain.0, plain.1 ^ chain.1, plain.2 ^ chain.2, plain.3 ^ chain.3), &output, offset)
            chain = cipher
            offset += 16
        }
        return output
    }

    func encryptEcb(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count % 16 == 0, "ECB works on whole blocks.")
        var output = [UInt8](repeating: 0, count: data.count)
        var offset = 0
        while offset < data.count {
            let plain: Block = (Aes.load(data, offset), Aes.load(data, offset + 4),
                                Aes.load(data, offset + 8), Aes.load(data, offset + 12))
            Aes.store(encrypt(plain), &output, offset)
            offset += 16
        }
        return output
    }

    func decryptEcb(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count % 16 == 0, "ECB works on whole blocks.")
        var output = [UInt8](repeating: 0, count: data.count)
        var offset = 0
        while offset < data.count {
            let cipher: Block = (Aes.load(data, offset), Aes.load(data, offset + 4),
                                 Aes.load(data, offset + 8), Aes.load(data, offset + 12))
            Aes.store(decrypt(cipher), &output, offset)
            offset += 16
        }
        return output
    }

    /// PKCS#7: one to sixteen bytes that each say how many there are.
    static func padded(_ data: [UInt8]) -> [UInt8] {
        let count = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(count), count: count)
    }

    /// The data without its PKCS#7 padding; nil when the padding is not valid.
    static func unpadded(_ data: [UInt8]) -> [UInt8]? {
        guard let last = data.last, last >= 1, last <= 16, Int(last) <= data.count else { return nil }
        let count = Int(last)
        for byte in data.suffix(count) where byte != last { return nil }
        return Array(data.dropLast(count))
    }

    private func encrypt(_ block: Block) -> Block {
        var s0 = block.0 ^ encryptKeys[0]
        var s1 = block.1 ^ encryptKeys[1]
        var s2 = block.2 ^ encryptKeys[2]
        var s3 = block.3 ^ encryptKeys[3]
        var k = 4
        for _ in 1..<rounds {
            let t0 = Aes.mixed(encryptTable, s0 >> 24, (s1 >> 16) & 0xFF, (s2 >> 8) & 0xFF, s3 & 0xFF) ^ encryptKeys[k]
            let t1 = Aes.mixed(encryptTable, s1 >> 24, (s2 >> 16) & 0xFF, (s3 >> 8) & 0xFF, s0 & 0xFF) ^ encryptKeys[k + 1]
            let t2 = Aes.mixed(encryptTable, s2 >> 24, (s3 >> 16) & 0xFF, (s0 >> 8) & 0xFF, s1 & 0xFF) ^ encryptKeys[k + 2]
            let t3 = Aes.mixed(encryptTable, s3 >> 24, (s0 >> 16) & 0xFF, (s1 >> 8) & 0xFF, s2 & 0xFF) ^ encryptKeys[k + 3]
            s0 = t0
            s1 = t1
            s2 = t2
            s3 = t3
            k += 4
        }
        return (Aes.last(sbox, s0, s1, s2, s3) ^ encryptKeys[k], Aes.last(sbox, s1, s2, s3, s0) ^ encryptKeys[k + 1],
                Aes.last(sbox, s2, s3, s0, s1) ^ encryptKeys[k + 2], Aes.last(sbox, s3, s0, s1, s2) ^ encryptKeys[k + 3])
    }

    private func decrypt(_ block: Block) -> Block {
        var s0 = block.0 ^ decryptKeys[0]
        var s1 = block.1 ^ decryptKeys[1]
        var s2 = block.2 ^ decryptKeys[2]
        var s3 = block.3 ^ decryptKeys[3]
        var k = 4
        for _ in 1..<rounds {
            let t0 = Aes.mixed(decryptTable, s0 >> 24, (s3 >> 16) & 0xFF, (s2 >> 8) & 0xFF, s1 & 0xFF) ^ decryptKeys[k]
            let t1 = Aes.mixed(decryptTable, s1 >> 24, (s0 >> 16) & 0xFF, (s3 >> 8) & 0xFF, s2 & 0xFF) ^ decryptKeys[k + 1]
            let t2 = Aes.mixed(decryptTable, s2 >> 24, (s1 >> 16) & 0xFF, (s0 >> 8) & 0xFF, s3 & 0xFF) ^ decryptKeys[k + 2]
            let t3 = Aes.mixed(decryptTable, s3 >> 24, (s2 >> 16) & 0xFF, (s1 >> 8) & 0xFF, s0 & 0xFF) ^ decryptKeys[k + 3]
            s0 = t0
            s1 = t1
            s2 = t2
            s3 = t3
            k += 4
        }
        return (Aes.last(inverseSbox, s0, s3, s2, s1) ^ decryptKeys[k], Aes.last(inverseSbox, s1, s0, s3, s2) ^ decryptKeys[k + 1],
                Aes.last(inverseSbox, s2, s1, s0, s3) ^ decryptKeys[k + 2], Aes.last(inverseSbox, s3, s2, s1, s0) ^ decryptKeys[k + 3])
    }

    /// One column of a round: the table entries of four bytes, each turned a byte further.
    private static func mixed(_ table: [UInt32], _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        table[Int(a)] ^ rotateRight(table[Int(b)], 8) ^ rotateRight(table[Int(c)], 16) ^ rotateRight(table[Int(d)], 24)
    }

    /// One column of the last round, which has no mixing: four substituted bytes.
    private static func last(_ box: [UInt8], _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        (UInt32(box[Int(a >> 24)]) << 24) | (UInt32(box[Int((b >> 16) & 0xFF)]) << 16)
            | (UInt32(box[Int((c >> 8) & 0xFF)]) << 8) | UInt32(box[Int(d & 0xFF)])
    }

    private static func substituted(_ box: [UInt8], _ w: UInt32) -> UInt32 {
        last(box, w, w, w, w)
    }

    private static func load(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16) | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    private static func store(_ block: Block, _ bytes: inout [UInt8], _ at: Int) {
        for (i, w) in [block.0, block.1, block.2, block.3].enumerated() {
            bytes[at + 4 * i] = UInt8(truncatingIfNeeded: w >> 24)
            bytes[at + 4 * i + 1] = UInt8(truncatingIfNeeded: w >> 16)
            bytes[at + 4 * i + 2] = UInt8(truncatingIfNeeded: w >> 8)
            bytes[at + 4 * i + 3] = UInt8(truncatingIfNeeded: w)
        }
    }
}
