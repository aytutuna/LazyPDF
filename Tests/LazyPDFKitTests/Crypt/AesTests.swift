import XCTest
@testable import LazyPDFKit

// No C# twin: the C# takes AES from System.Security.Cryptography. These check the engine's own against the
// vectors of FIPS 197 appendix C and NIST SP 800-38A F.2.1, and round-trip longer inputs.

final class AesTests: XCTestCase {
    func test_fips197BlocksForEachKeySize() {
        let plain = Hex.bytes("00112233445566778899AABBCCDDEEFF")
        let cases = [
            ("000102030405060708090A0B0C0D0E0F", "69C4E0D86A7B0430D8CDB78070B4C55A"),
            ("000102030405060708090A0B0C0D0E0F1011121314151617", "DDA97CA4864CDFE06EAF70A0EC0D7191"),
            ("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", "8EA2B7CA516745BFEAFC49904B496089"),
        ]
        for (key, expected) in cases {
            let aes = Aes(key: Hex.bytes(key))

            XCTAssertEqual(Hex.string(aes.encryptEcb(plain)), expected, key)
            XCTAssertEqual(aes.decryptEcb(Hex.bytes(expected)), plain, key)
        }
    }

    func test_cbcFirstBlockOfSp80038a() {
        let aes = Aes(key: Hex.bytes("2B7E151628AED2A6ABF7158809CF4F3C"))
        let iv = Hex.bytes("000102030405060708090A0B0C0D0E0F")
        let plain = Hex.bytes("6BC1BEE22E409F96E93D7E117393172A")

        XCTAssertEqual(Hex.string(aes.encryptCbc(plain, iv: iv)), "7649ABAC8119B246CEE98E9B12E9197D")
        XCTAssertEqual(aes.decryptCbc(Hex.bytes("7649ABAC8119B246CEE98E9B12E9197D"), iv: iv), plain)
    }

    func test_cbcRoundTripsLongData() {
        var random = SeededRandom(8)
        for size in [16, 32, 160, 4096] {
            for keySize in [16, 24, 32] {
                let aes = Aes(key: random.bytes(keySize))
                let iv = random.bytes(16)
                let data = random.bytes(size)

                XCTAssertEqual(aes.decryptCbc(aes.encryptCbc(data, iv: iv), iv: iv), data, "\(keySize) \(size)")
            }
        }
    }

    func test_paddingIsPkcs7() {
        XCTAssertEqual(Aes.padded([]), [UInt8](repeating: 16, count: 16))
        XCTAssertEqual(Aes.padded([1, 2, 3]).count, 16)
        XCTAssertEqual(Aes.padded([UInt8](repeating: 9, count: 16)).count, 32)
        XCTAssertEqual(Aes.unpadded(Aes.padded([1, 2, 3])), [1, 2, 3])
        XCTAssertEqual(Aes.unpadded(Aes.padded([])), [])
    }

    func test_badPaddingIsRefused() {
        XCTAssertNil(Aes.unpadded([]))
        XCTAssertNil(Aes.unpadded([UInt8](repeating: 0, count: 16)))
        XCTAssertNil(Aes.unpadded([UInt8](repeating: 17, count: 16)))
        XCTAssertNil(Aes.unpadded([UInt8](repeating: 1, count: 15) + [3]))
    }
}
