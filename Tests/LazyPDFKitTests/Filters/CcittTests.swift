import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/CcittTests.cs: the same cases.

final class CcittTests: XCTestCase {
    private let eol = "000000000001"

    private func bits(_ parts: String...) -> [UInt8] {
        let all = Array(parts.joined())
        var bytes = [UInt8](repeating: 0, count: (all.count + 7) / 8)
        for i in 0..<all.count where all[i] == "1" { bytes[i / 8] |= UInt8(0x80 >> (i % 8)) }
        return bytes
    }

    /// Rows of packed pixels with white as 1 and black as 0, padding bits white; or the other way round.
    private func pack(_ width: Int, _ height: Int, blackIs1: Bool = false, _ black: (Int, Int) -> Bool) -> [UInt8] {
        let stride = (width + 7) / 8
        var packed = [UInt8](repeating: blackIs1 ? 0 : 0xFF, count: stride * height)
        for y in 0..<height {
            for x in 0..<width where black(x, y) {
                if blackIs1 { packed[y * stride + (x >> 3)] |= UInt8(0x80 >> (x & 7)) } else { packed[y * stride + (x >> 3)] &= ~UInt8(0x80 >> (x & 7)) }
            }
        }
        return packed
    }

    private func decode(_ data: [UInt8], _ parms: String) throws -> [UInt8] {
        try PdfFilters.decode(data, PdfName("CCITTFaxDecode"), try FilterFixtures.dict(parms))
    }

    private func parms(_ k: Int, _ width: Int, _ rows: Int? = nil, align: Bool = false, blackIs1: Bool = false, eol: Bool = false) -> String {
        "<< /K \(k) /Columns \(width) \(rows.map { "/Rows \($0)" } ?? "") /EncodedByteAlign \(align) /BlackIs1 \(blackIs1) /EndOfLine \(eol) >>"
    }

    private let images: [(width: Int, height: Int, black: (Int, Int) -> Bool)] = [
        (61, 40, { x, y in (x / 7 + y / 3) % 2 == 0 }),
        (100, 20, { _, _ in false }),
        (33, 9, { _, _ in true }),
        (17, 6, { x, y in x == 16 && y == 5 || x == 0 && y == 0 }),
        (80, 80, { x, y in abs(x - y) < 3 }),
        (90, 50, { x, y in (((x * 31 + y * 17) * 2654435761) >> 20) & 7 == 0 }),
        (6100, 7, { x, y in x % 5000 < 3000 + y * 100 && x > 40 }),
        (1, 12, { _, y in y % 3 == 0 }),
        (8, 16, { x, y in (x + y) % 5 < 2 }),
    ]

    func test_groupFourRoundTrips() throws {
        for (width, height, black) in images {
            let packed = pack(width, height, black)
            let encoded = CcittEncoder.encode(packed, width, height)
            XCTAssertEqual(try decode(encoded, parms(-1, width, height)), packed, "\(width)x\(height)")
            XCTAssertEqual(try decode(encoded, parms(-1, width)), packed, "\(width)x\(height) no rows")
        }
    }

    func test_blackIs1FlipsTheColours() throws {
        for (width, height, black) in images {
            let encoded = CcittEncoder.encode(pack(width, height, black), width, height)
            XCTAssertEqual(try decode(encoded, parms(-1, width, height, blackIs1: true)), pack(width, height, blackIs1: true, black), "\(width)x\(height)")
        }
    }

    func test_groupThreeOneDimensionalRoundTrips() throws {
        for (width, height, black) in images {
            let packed = pack(width, height, black)
            for (eol, align) in [(false, false), (true, false), (false, true), (true, true)] {
                let encoded = CcittEncoder.encodeG3(packed, width, height, 0, eol: eol, align: align)
                XCTAssertEqual(try decode(encoded, parms(0, width, height, align: align, eol: eol)), packed, "\(width)x\(height) rows eol=\(eol) align=\(align)")
                XCTAssertEqual(try decode(encoded, parms(0, width, align: align, eol: eol)), packed, "\(width)x\(height) norows eol=\(eol) align=\(align)")
            }
        }
    }

    func test_groupThreeMixedRoundTrips() throws {
        for (width, height, black) in images {
            let packed = pack(width, height, black)
            for k in [2, 4] {
                for align in [false, true] {
                    let encoded = CcittEncoder.encodeG3(packed, width, height, k, eol: true, align: align)
                    XCTAssertEqual(try decode(encoded, parms(k, width, height, align: align, eol: true)), packed, "\(width)x\(height) k=\(k) align=\(align)")
                    XCTAssertEqual(try decode(encoded, parms(k, width, align: align, eol: true)), packed, "\(width)x\(height) k=\(k) align=\(align) norows")
                }
            }
        }
    }

    func test_groupFourKnownAnswer() throws {
        // Row 1 all white: V0. Row 2 black from 2 to 4: horizontal (white 2, black 3), then V0 for the end.
        let data = bits("1", "001", "0111", "10", "1", eol, eol)
        XCTAssertEqual(try decode(data, parms(-1, 8)), [0xFF, 0xC7])
    }

    func test_groupThreeKnownAnswer() throws {
        // One row, width 16: white 3 (1000), black 2 (11), white 11 (10101).
        XCTAssertEqual(try decode(bits("1000", "11", "01000"), parms(0, 16)), [0b11100111, 0xFF])
    }

    func test_endOfLineFlagIsNotNeededToAcceptEols() throws {
        let packed = pack(40, 10) { x, y in (x + y) % 6 < 2 }
        let encoded = CcittEncoder.encodeG3(packed, 40, 10, 0, eol: true, align: false)
        XCTAssertEqual(try decode(encoded, parms(0, 40, eol: false)), packed)
    }

    func test_missingRowsAreWhite() throws {
        let packed = pack(20, 5) { _, _ in true }
        let encoded = CcittEncoder.encode(packed, 20, 5)
        let decoded = try decode(encoded, parms(-1, 20, 9))
        XCTAssertEqual(decoded.count, 9 * 3)
        XCTAssertEqual(Array(decoded[..<(5 * 3)]), packed)
        XCTAssertTrue(decoded[(5 * 3)...].allSatisfy { $0 == 0xFF })
    }

    func test_fewerRowsThanTheDataHoldStopsEarly() throws {
        let packed = pack(20, 8) { x, y in (x + y) % 3 == 0 }
        let encoded = CcittEncoder.encode(packed, 20, 8)
        XCTAssertEqual(try decode(encoded, parms(-1, 20, 3)), Array(packed[..<(3 * 3)]))
    }

    func test_truncatedGroupFourKeepsTheRowsBeforeTheBreak() throws {
        let packed = pack(64, 40) { x, y in (x / 5 + y / 2) % 2 == 0 }
        let encoded = CcittEncoder.encode(packed, 64, 40)
        let decoded = try decode(Array(encoded[..<(encoded.count / 2)]), parms(-1, 64, 40))
        XCTAssertEqual(decoded.count, packed.count)
        XCTAssertEqual(Array(decoded[..<(8 * 10)]), Array(packed[..<(8 * 10)]))
    }

    func test_groupThreeResynchronisesAtTheNextEol() throws {
        // Rows: white; a bad code with a few stray bits; black.
        let data = bits(eol, "10011", eol, "000000001", "101", eol, "00110101", "000101", eol, eol, eol)
        XCTAssertEqual(try decode(data, parms(0, 8, 3)), [0xFF, 0xFF, 0x00])
    }

    func test_returnToControlEndsTheData() throws {
        let data = bits(eol, "10011", eol, "00110101", "000101", eol, eol, eol, eol, eol, eol, "1010101")
        XCTAssertEqual(try decode(data, parms(0, 8)), [0xFF, 0x00])
    }

    func test_garbageDoesNotThrowAndStaysBounded() throws {
        let garbage = FilterFixtures.randomBytes(20_000, 11)
        for k in [-1, 0, 3] {
            let decoded = try decode(garbage, parms(k, 200))
            XCTAssertEqual(decoded.count % 25, 0, "k=\(k)")
            let withRows = try decode(garbage, parms(k, 200, 100))
            XCTAssertEqual(withRows.count, 2500, "k=\(k)")
        }
    }

    func test_zeroBytesDecodeToNothing() throws {
        XCTAssertTrue(try decode([UInt8](repeating: 0, count: 100), parms(-1, 64)).isEmpty)
        XCTAssertTrue(try decode([], parms(0, 64)).isEmpty)
        XCTAssertEqual(try decode([], parms(0, 24, 8)).count, 8 * 3)
    }

    func test_columnsOutOfRangeAreDamaged() {
        assertProblem(.damaged, try decode([1, 2, 3], parms(-1, 0)))
        assertProblem(.damaged, try decode([1, 2, 3], parms(-1, 1 << 24)))
    }

    func test_rowsTimesWidthPastTheCapIsUnsupportedBeforeAllocating() throws {
        let p = try FilterFixtures.dict("<< /K -1 /Columns 100000 /Rows 2000000000 >>")
        assertProblem(.unsupported, try PdfFilters.decode([0xFF], PdfName("CCF"), p))
    }

    func test_manyOneBitRowsStopAtTheCap() throws {
        // Each V0 bit is a whole row of 128 KB: the cap, not the data size, bounds the output.
        let data = [UInt8](repeating: 0xFF, count: 200_000)
        let p = try FilterFixtures.dict("<< /K -1 /Columns 1000000 >>")
        assertProblem(.unsupported, try PdfFilters.decode(data, PdfName("CCITTFaxDecode"), p, 50_000_000))
    }

    func test_defaultColumnsAre1728() throws {
        let packed = pack(1728, 3) { x, _ in x > 100 && x < 900 }
        let encoded = CcittEncoder.encode(packed, 1728, 3)
        XCTAssertEqual(try PdfFilters.decode(encoded, PdfName("CCF"), try FilterFixtures.dict("<< /K -1 >>")), packed)
    }

    func test_chainsWithAsciiAndFlate() throws {
        let packed = pack(70, 30) { x, y in (x * y) % 11 < 4 }
        let encoded = CcittEncoder.encode(packed, 70, 30)
        let stored = PdfFilterEncoders.ascii85(PdfFilterEncoders.flate(encoded))
        let p = try FilterFixtures.parse("[null null << /K -1 /Columns 70 /Rows 30 >>]")
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("[/A85 /Fl /CCF]"), p), packed)
    }

    func test_emptyHorizontalRunsCannotPushVerticalCodesPastTheRow() throws {
        let empty = "001" + "0000110111" + "00110101"
        let data = bits("0000010", empty, empty, empty, empty, "000010", "010")
        do {
            _ = try decode(data, parms(-1, 8, 1))
        } catch {
            XCTAssertTrue(error is PdfReadException, "\(error)")
        }
    }
}
