import XCTest
@testable import LazyPDFKit

// No C# twin: the C# gets RC2 and 3DES from EnvelopedCms. These check Rc2.swift and Des.swift against the
// reference vectors (RFC 2268 5, FIPS 46) and against what the .NET RC2 and 3DES providers made of fixed keys.

final class LegacyCipherTests: XCTestCase {
    private let text = Array("0123456789abcdefghijklmnopq".utf8)
    private let vector = Hex.bytes("C8C9CACBCCCDCECF")

    private func envelope(_ algorithm: String, bits: Int = 0, _ encrypted: String) -> PdfEnvelopedData {
        PdfEnvelopedData(recipients: [], contentAlgorithm: algorithm, iv: vector, encryptedContent: Hex.bytes(encrypted), rc2Bits: bits)
    }

    func test_rc2FollowsTheReferenceVectors() throws {
        let cases: [(key: String, bits: Int, plain: String, cipher: String)] = [
            ("0000000000000000", 63, "0000000000000000", "EBB773F993278EFF"),
            ("FFFFFFFFFFFFFFFF", 64, "FFFFFFFFFFFFFFFF", "278B27E42E2F0D49"),
            ("3000000000000000", 64, "1000000000000001", "30649EDF9BE7D2C2"),
            ("88BCA90E90875A7F0F79C384627BAFB2", 128, "0000000000000000", "2269552AB0F85CA6"),
        ]
        for item in cases {
            let rc2 = try XCTUnwrap(Rc2(key: Hex.bytes(item.key), effectiveBits: item.bits), item.key)

            let plain = rc2.decryptCbc(Hex.bytes(item.cipher), iv: [UInt8](repeating: 0, count: 8))

            XCTAssertEqual(Hex.string(plain), item.plain, "\(item.key) at \(item.bits) bits")
        }
    }

    func test_rc2OpensWhatTheSystemSealed() {
        let at128 = envelope(PdfCms.rc2Cbc, bits: 128, "5FC18E1EAE3A0CE05F0F46007AE25D0D4DDCD47E0A936E892A9963613E86BDE3")
        let at40 = envelope(PdfCms.rc2Cbc, bits: 40, "FCC7C4F839E37C9C580326B8CC6CFF3193C6CE499E80399FE89F1AF5FA617C19")

        XCTAssertEqual(PdfCms.decryptContent(at128, key: Hex.bytes("01080F161D242B323940474E555C636A")), text)
        XCTAssertEqual(PdfCms.decryptContent(at40, key: Hex.bytes("01080F161D")), text)
    }

    func test_rc2RefusesWhatItCannotUse() {
        XCTAssertNil(Rc2(key: [], effectiveBits: 40))
        XCTAssertNil(Rc2(key: [UInt8](repeating: 1, count: 129), effectiveBits: 128))
        XCTAssertNil(Rc2(key: [1, 2, 3, 4, 5], effectiveBits: 0))
        XCTAssertNil(Rc2(key: [1, 2, 3, 4, 5], effectiveBits: 1025))
        XCTAssertNotNil(Rc2(key: [UInt8](repeating: 1, count: 128), effectiveBits: 1024))
        XCTAssertNotNil(Rc2(key: [1], effectiveBits: 1))
        let sealed = envelope(PdfCms.rc2Cbc, bits: 128, "5FC18E1EAE3A0CE05F0F46007AE25D0D4DDCD47E0A936E892A9963613E86BDE3")
        let key = Hex.bytes("01080F161D242B323940474E555C636A")
        var short = sealed
        short.encryptedContent.removeLast()
        XCTAssertNil(PdfCms.decryptContent(short, key: key), "a cipher text that is not whole blocks")
        var noVector = sealed
        noVector.iv = []
        XCTAssertNil(PdfCms.decryptContent(noVector, key: key), "an IV of the wrong size")
        var noBits = sealed
        noBits.rc2Bits = 0
        XCTAssertNil(PdfCms.decryptContent(noBits, key: key), "no effective key length")
    }

    func test_desFollowsTheStandardVector() throws {
        let key = Hex.bytes("133457799BBCDFF1")
        let des = try XCTUnwrap(TripleDes(key: key + key + key))

        let plain = des.decryptCbc(Hex.bytes("85E813540F0AB405"), iv: [UInt8](repeating: 0, count: 8))

        XCTAssertEqual(Hex.string(plain), "0123456789ABCDEF")
    }

    func test_tripleDesOpensWhatTheSystemSealed() {
        let sealed = envelope(PdfCms.tripleDesCbc, "10633743D911B500CED3623CAD14048F5A16E35911CD69743D649A7F576F992B")
        let key = Hex.bytes("030E19242F3A45505B66717C87929DA8B3BEC9D4DFEAF500")

        XCTAssertEqual(PdfCms.decryptContent(sealed, key: key), text)
        XCTAssertNil(PdfCms.decryptContent(sealed, key: Array(key.prefix(16))), "two keys")
        XCTAssertNil(PdfCms.decryptContent(sealed, key: key + [0]), "a key too long")
        var short = sealed
        short.encryptedContent.removeLast()
        XCTAssertNil(PdfCms.decryptContent(short, key: key), "a cipher text that is not whole blocks")
        var noVector = sealed
        noVector.iv = Array(vector.prefix(7))
        XCTAssertNil(PdfCms.decryptContent(noVector, key: key), "an IV of the wrong size")
    }
}
