import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/ToUnicodeCMapTests.cs: the same cases. `write` throws
// ToUnicodeCMap.OutOfRange where the C# throws ArgumentOutOfRangeException.

final class ToUnicodeCMapTests: XCTestCase {
    private func text(_ data: [UInt8]) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func unit(_ value: Int) -> String {
        String(decoding: [UInt16(value)], as: UTF16.self)
    }

    func test_roundTripsThroughTheParser() throws {
        let pairs: [Int: String] = [
            0x0001: "A", 0x0002: "B", 0x0003: "C", 0x0010: "fi", 0x0020: "\u{1F600}",
            0x0021: "\u{1F601}", 0x0100: "\u{FE}", 0x0101: "\u{FF}", 0x0102: "\u{100}", 0xFFFF: "\u{4E2D}",
        ]
        let map = CMap.parse(try ToUnicodeCMap.write(Array(pairs)))
        for (code, expected) in pairs {
            XCTAssertEqual(map.unicodeOf(code), expected)
        }
        XCTAssertNil(map.unicodeOf(0x0004))
        let next = map.nextCode([0x00, 0x01][...])
        XCTAssertEqual(next.code, 0x0001)
        XCTAssertEqual(next.length, 2)
    }

    func test_runsBecomeBfRanges() throws {
        let pairs = (0..<10).map { (key: 0x20 + $0, value: unit(Int(UInt8(ascii: "a")) + $0)) }
        let cmap = text(try ToUnicodeCMap.write(pairs))
        XCTAssertTrue(cmap.contains("1 beginbfrange\n<0020> <0029> <0061>\nendbfrange"))
        XCTAssertFalse(cmap.contains("beginbfchar"))
    }

    func test_rangesDoNotCrossALowByteWrap() throws {
        let pairs = (0xFE..<0xFE + 4).map { (key: $0, value: unit($0)) }
        let map = CMap.parse(try ToUnicodeCMap.write(pairs))
        for (code, expected) in pairs {
            XCTAssertEqual(map.unicodeOf(code), expected)
        }
        XCTAssertFalse(text(try ToUnicodeCMap.write(pairs)).contains("<00FE> <0101>"))
    }

    func test_sectionsHoldAtMost100Entries() throws {
        let pairs = (0..<250).map { (key: $0 * 2, value: "x" + unit(0x4E00 + $0 * 3)) }
        let cmap = text(try ToUnicodeCMap.write(pairs))
        XCTAssertTrue(cmap.contains("100 beginbfchar"))
        XCTAssertTrue(cmap.contains("50 beginbfchar"))
        let map = CMap.parse(Array(cmap.utf8))
        XCTAssertEqual(map.unicodeOf(498), "x" + unit(0x4E00 + 249 * 3))
    }

    func test_lastTextForACodeWinsAndEmptyTextIsLeftOut() throws {
        let map = CMap.parse(try ToUnicodeCMap.write([(key: 5, value: "a"), (key: 5, value: "b"), (key: 6, value: "")]))
        XCTAssertEqual(map.unicodeOf(5), "b")
        XCTAssertNil(map.unicodeOf(6))
    }

    func test_oneByteCodes() throws {
        let data = try ToUnicodeCMap.write([(key: 0x41, value: "Z")], codeBytes: 1)
        XCTAssertTrue(text(data).contains("<00> <FF>"))
        let map = CMap.parse(data)
        XCTAssertEqual(map.unicodeOf(0x41), "Z")
        XCTAssertEqual(map.nextCode([0x41, 0x42][...]).length, 1)
    }

    func test_hasTheFixedFrame() throws {
        let cmap = text(try ToUnicodeCMap.write([]))
        XCTAssertTrue(cmap.hasPrefix("/CIDInit /ProcSet findresource begin"))
        XCTAssertTrue(cmap.contains("begincmap"))
        XCTAssertTrue(cmap.contains("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange"))
        XCTAssertTrue(cmap.hasSuffix("end\nend\n"))
    }

    func test_rejectsWhatDoesNotFit() {
        XCTAssertThrowsError(try ToUnicodeCMap.write([(key: 0x10000, value: "a")]))
        XCTAssertThrowsError(try ToUnicodeCMap.write([(key: -1, value: "a")]))
        XCTAssertThrowsError(try ToUnicodeCMap.write([], codeBytes: 5))
    }
}
