import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/Rc4Tests.cs: the same cases.

final class Rc4Tests: XCTestCase {
    func test_matchesPublishedVectors() {
        let cases = [("Key", "Plaintext", "BBF316E8D940AF0AD3"), ("Wiki", "pedia", "1021BF0420"),
                     ("Secret", "Attack at dawn", "45A01F645FC35B383552544B9BF5")]
        for (key, text, expected) in cases {
            let output = Rc4.apply(Array(key.utf8), Array(text.utf8))

            XCTAssertEqual(Hex.string(output), expected, key)
        }
    }

    func test_appliedTwiceGivesTheInput() {
        let key: [UInt8] = [1, 2, 3, 4, 5]
        var random = SeededRandom(2)
        let data = random.bytes(1000)

        XCTAssertEqual(Rc4.apply(key, Rc4.apply(key, data)), data)
    }

    func test_keyLongerThan256BytesWorks() {
        var random = SeededRandom(4)
        let key = random.bytes(300)

        XCTAssertEqual(Rc4.apply(key, [UInt8](repeating: 0, count: 10)).count, 10)
    }
}
