import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/FlateTests.cs: the same cases. RawDeflateIsAccepted has no
// DeflateStream to make its input, so it takes the zlib stream the encoder writes without its header and checksum.

final class FlateTests: XCTestCase {
    private func name(_ value: String) -> PdfName { PdfName(value) }

    func test_encodedDataDecodesAtEveryLevel() throws {
        let data = FilterFixtures.text(50_000)
        for level in [CompressionLevel.optimal, .fastest, .noCompression, .smallestSize] {
            let packed = PdfFilterEncoders.flate(data, level)
            XCTAssertEqual(try PdfFilters.decode(packed, name("FlateDecode"), nil), data, "\(level)")
        }
    }

    func test_smallestSizeIsNotLargerThanFastest() {
        let data = FilterFixtures.text(50_000)
        XCTAssertLessThanOrEqual(PdfFilterEncoders.flate(data, .smallestSize).count, PdfFilterEncoders.flate(data, .fastest).count)
    }

    func test_emptyDataIsEmpty() throws {
        XCTAssertTrue(try PdfFilters.decode([], name("FlateDecode"), nil).isEmpty)
        XCTAssertTrue(try PdfFilters.decode(PdfFilterEncoders.flate([]), name("Fl"), nil).isEmpty)
    }

    func test_cleanEmptyStreamIsEmpty() throws {
        XCTAssertTrue(try PdfFilters.decode([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01], name("FlateDecode"), nil).isEmpty)
        XCTAssertTrue(try PdfFilters.decode([0x03, 0x00], name("FlateDecode"), nil).isEmpty)
    }

    func test_emptyResultWithoutACleanEndIsDamaged() {
        let cases: [[UInt8]] = [[0x78, 0x9C], [0xFF, 0xFF, 0xFF], [0x78, 0x9C, 0x01, 0x05, 0x00]]
        for data in cases {
            XCTAssertThrowsError(try PdfFilters.decode(data, name("FlateDecode"), nil)) { error in
                let e = error as? PdfReadException
                XCTAssertEqual(e?.problem, .damaged)
                XCTAssertEqual(e?.message, "A compressed stream does not inflate.")
            }
        }
    }

    func test_truncatedDataGivesWhatDecoded() throws {
        let data = FilterFixtures.randomBytes(40_000)
        let packed = PdfFilterEncoders.flate(data, .noCompression)
        let decoded = try PdfFilters.decode(Array(packed[..<(packed.count / 2)]), name("FlateDecode"), nil)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertLessThan(decoded.count, data.count)
        XCTAssertEqual(Array(data[..<decoded.count]), decoded)
    }

    func test_strictDecodingTakesABreakOffForDamage() throws {
        let data = FilterFixtures.text(100_000)
        let packed = PdfFilterEncoders.flate(data)
        let cut = Array(packed[..<(packed.count / 2)])
        XCTAssertFalse(try PdfFilters.decode(cut, name("FlateDecode"), nil).isEmpty)
        XCTAssertThrowsError(try PdfFilters.decode(cut, name("FlateDecode"), nil, PdfFilters.defaultMaxSize, strict: true)) { error in
            let e = error as? PdfReadException
            XCTAssertEqual(e?.problem, .damaged)
            XCTAssertEqual(e?.message, "A compressed stream breaks off.")
        }
        XCTAssertEqual(try PdfFilters.decode(packed, name("FlateDecode"), nil, PdfFilters.defaultMaxSize, strict: true), data)
        XCTAssertEqual(try PdfFilters.decode(Array(packed.dropLast(4)), name("FlateDecode"), nil, PdfFilters.defaultMaxSize, strict: true), data)
    }

    func test_badChecksumStillGivesTheData() throws {
        let data = FilterFixtures.text(10_000)
        var packed = PdfFilterEncoders.flate(data)
        packed[packed.count - 1] ^= 0xFF
        XCTAssertEqual(try PdfFilters.decode(packed, name("FlateDecode"), nil), data)
    }

    func test_missingChecksumStillGivesTheData() throws {
        let data = FilterFixtures.text(10_000)
        let packed = PdfFilterEncoders.flate(data)
        XCTAssertEqual(try PdfFilters.decode(Array(packed[..<(packed.count - 4)]), name("FlateDecode"), nil), data)
    }

    func test_rawDeflateIsAccepted() throws {
        let data = FilterFixtures.text(10_000)
        let packed = PdfFilterEncoders.flate(data)
        XCTAssertEqual(try PdfFilters.inflate(Array(packed[2..<(packed.count - 4)])), data)
    }

    func test_garbageIsDamaged() {
        assertProblem(.damaged, try PdfFilters.decode(FilterFixtures.randomBytes(500, 3), name("FlateDecode"), nil))
    }

    func test_expansionPastTheCapIsUnsupported() throws {
        let packed = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 20_000_000))
        XCTAssertLessThan(packed.count, 100_000)
        assertProblem(.unsupported, try PdfFilters.decode(packed, name("FlateDecode"), nil, 1_000_000))
        XCTAssertEqual(try PdfFilters.decode(packed, name("FlateDecode"), nil, 20_000_000).count, 20_000_000)
    }

    // Not in the C# tests. The totals are what DeflateStream returns for the same bytes, read through PdfFilters'
    // loop on Windows: a data error loses the stretch it was working on, which ends at each 8 KB of input and
    // each 64 KB of output.
    func test_dataThatBreaksOffGivesTheSameBytesAsDeflateStream() throws {
        func stored(_ length: Int) -> [UInt8] {
            let complement = ~length & 0xFFFF
            let data = (0..<length).map { UInt8($0 % 251) }
            return [0, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(complement & 0xFF), UInt8(complement >> 8)] + data + [7]
        }
        for (length, expected) in [(1000, 0), (8000, 0), (8190, 8187), (8300, 8187), (20000, 16379), (30000, 24571)] {
            let output = FilterBuffer(PdfFilters.defaultMaxSize)
            XCTAssertFalse(try Flate.inflate(stored(length), 0, output))
            XCTAssertEqual(output.count, expected, "\(length) stored bytes")
        }
        // 70000 zero bytes, flushed, then a block header that is not one.
        let zeros = "ECC13101000000C2A0F54F6D094FA000" + String(repeating: "0", count: 132) + "80CE060000FFFF07"
        var bytes: [UInt8] = []
        var index = zeros.startIndex
        while index < zeros.endIndex {
            let next = zeros.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(zeros[index..<next], radix: 16)))
            index = next
        }
        let output = FilterBuffer(PdfFilters.defaultMaxSize)
        XCTAssertFalse(try Flate.inflate(bytes, 0, output))
        XCTAssertEqual(output.count, 65536)
    }

    func test_zeroBombPastTheDefaultCapIsRefused() {
        let packed = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 300 << 20))
        XCTAssertThrowsError(try PdfFilters.decode(packed, name("FlateDecode"), nil)) { error in
            let e = error as? PdfReadException
            XCTAssertEqual(e?.problem, .unsupported)
            XCTAssertEqual(e?.message, "A stream expands past the size limit.")
        }
    }

    func test_largeZeroStreamUnderTheCapDecodesWhole() throws {
        let packed = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 64 << 20))
        XCTAssertEqual(try PdfFilters.decode(packed, name("FlateDecode"), nil).count, 64 << 20)
    }

    func test_kibibyteCapStillStops() {
        let packed = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 4096))
        assertProblem(.unsupported, try PdfFilters.decode(packed, name("FlateDecode"), nil, 1024))
    }
}
