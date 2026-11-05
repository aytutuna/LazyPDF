import Foundation

// MD5, SHA-1 and SHA-2 for the security handlers. The C# takes them from System.Security.Cryptography; LazyPDFKit
// imports Foundation alone and also builds on Linux, so they are written out here (RFC 1321, FIPS 180-4) and give
// the same bytes on every platform.

private func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x << n) | (x >> (32 - n))
}

private func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
}

private func rotateRight(_ x: UInt64, _ n: UInt64) -> UInt64 {
    (x >> n) | (x << (64 - n))
}

/// The message, a 1 bit, zeros and the length in bits, up to a whole number of blocks.
private func padded(_ data: [UInt8], blockSize: Int, bigEndian: Bool) -> [UInt8] {
    let lengthSize = blockSize / 8
    var message = data
    message.append(0x80)
    while (message.count + lengthSize) % blockSize != 0 { message.append(0) }
    let bits = UInt64(data.count) &* 8
    var length = [UInt8](repeating: 0, count: lengthSize)
    for i in 0..<8 {
        let byte = UInt8(truncatingIfNeeded: bits >> UInt64(8 * i))
        length[bigEndian ? lengthSize - 1 - i : i] = byte
    }
    message.append(contentsOf: length)
    return message
}

private func word(_ bytes: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32 {
    let b0 = UInt32(bytes[at]), b1 = UInt32(bytes[at + 1]), b2 = UInt32(bytes[at + 2]), b3 = UInt32(bytes[at + 3])
    return bigEndian ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3 : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
}

private func word64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
    (UInt64(word(bytes, at, bigEndian: true)) << 32) | UInt64(word(bytes, at + 4, bigEndian: true))
}

private func bytes(_ words: [UInt32], bigEndian: Bool) -> [UInt8] {
    var output: [UInt8] = []
    for w in words {
        let four = [UInt8(truncatingIfNeeded: w >> 24), UInt8(truncatingIfNeeded: w >> 16),
                    UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w)]
        output.append(contentsOf: bigEndian ? four : Array(four.reversed()))
    }
    return output
}

private func bytes(_ words: [UInt64]) -> [UInt8] {
    var output: [UInt8] = []
    for w in words {
        for shift in stride(from: 56, through: 0, by: -8) {
            output.append(UInt8(truncatingIfNeeded: w >> UInt64(shift)))
        }
    }
    return output
}

enum Md5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    static func hash(_ data: [UInt8]) -> [UInt8] {
        let message = padded(data, blockSize: 64, bigEndian: false)
        var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        var m = [UInt32](repeating: 0, count: 16)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 { m[i] = word(message, offset + 4 * i, bigEndian: false) }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i / 16 {
                case 0:
                    f = (b & c) | (~b & d)
                    g = i
                case 1:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 2:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotateLeft(f, shifts[i])
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            offset += 64
        }
        return bytes(state, bigEndian: false)
    }
}

enum Sha1 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        let message = padded(data, blockSize: 64, bigEndian: true)
        var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var w = [UInt32](repeating: 0, count: 80)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 { w[i] = word(message, offset + 4 * i, bigEndian: true) }
            for i in 16..<80 { w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                if i < 20 {
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                } else if i < 40 {
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                } else if i < 60 {
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                } else {
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let t = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = t
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            offset += 64
        }
        return bytes(state, bigEndian: true)
    }
}

enum Sha256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: [UInt8]) -> [UInt8] {
        let message = padded(data, blockSize: 64, bigEndian: true)
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 { w[i] = word(message, offset + 4 * i, bigEndian: true) }
            for i in 16..<64 {
                let x = w[i - 15], y = w[i - 2]
                let s0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >> 3)
                let s1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ constants[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
            offset += 64
        }
        return bytes(state, bigEndian: true)
    }
}

/// SHA-512 and, with another start and a shorter result, SHA-384.
private enum Sha512Core {
    private static let constants: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f,
        0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
        0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242,
        0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
        0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275,
        0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f,
        0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc,
        0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6,
        0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
        0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99,
        0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
        0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc,
        0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915,
        0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
        0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba,
        0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
        0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    static func hash(_ data: [UInt8], start: [UInt64]) -> [UInt8] {
        let message = padded(data, blockSize: 128, bigEndian: true)
        var state = start
        var w = [UInt64](repeating: 0, count: 80)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 { w[i] = word64(message, offset + 8 * i) }
            for i in 16..<80 {
                let x = w[i - 15], y = w[i - 2]
                let s0 = rotateRight(x, 1) ^ rotateRight(x, 8) ^ (x >> 7)
                let s1 = rotateRight(y, 19) ^ rotateRight(y, 61) ^ (y >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<80 {
                let s1 = rotateRight(e, 14) ^ rotateRight(e, 18) ^ rotateRight(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ constants[i] &+ w[i]
                let s0 = rotateRight(a, 28) ^ rotateRight(a, 34) ^ rotateRight(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
            offset += 128
        }
        return bytes(state)
    }

    static let sha512Start: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    static let sha384Start: [UInt64] = [
        0xcbbb9d5dc1059ed8, 0x629a292a367cd507,
        0x9159015a3070dd17, 0x152fecd8f70e5939,
        0x67332667ffc00b31, 0x8eb44a8768581511,
        0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
    ]
}

enum Sha384 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        Array(Sha512Core.hash(data, start: Sha512Core.sha384Start).prefix(48))
    }
}

enum Sha512 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        Sha512Core.hash(data, start: Sha512Core.sha512Start)
    }
}
