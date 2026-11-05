import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/LzwTests.cs: the same cases.

final class LzwTests: XCTestCase {
    private func decode(_ data: [UInt8], _ parms: String? = nil) throws -> [UInt8] {
        try PdfFilters.decode(data, PdfName("LZWDecode"), parms.map { try FilterFixtures.dict($0) })
    }

    private let specPlain: [UInt8] = [45, 45, 45, 45, 45, 65, 45, 45, 45, 66]
    private let specCoded: [UInt8] = [0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01]

    func test_specExampleDecodes() throws {
        // ISO 32000-1 7.4.4.2.
        XCTAssertEqual(try decode(specCoded), specPlain)
    }

    func test_encoderMatchesTheSpecExample() {
        XCTAssertEqual(PdfFilterEncoders.lzw(specPlain), specCoded)
    }

    func test_textRoundTripsAcrossCodeWidthsAndTableResets() throws {
        let cases: [(Int, Bool)] = [(0, true), (1, true), (2, true), (300, true), (5000, true), (200_000, true),
                                    (0, false), (5000, false), (200_000, false)]
        for (length, early) in cases {
            let data = FilterFixtures.text(length)
            let encoded = PdfFilterEncoders.lzw(data, early)
            XCTAssertEqual(try decode(encoded, early ? nil : "<< /EarlyChange 0 >>"), data, "\(length) \(early)")
        }
    }

    func test_randomDataRoundTripsAndRepeatedBytesToo() throws {
        let random = FilterFixtures.randomBytes(100_000, 8)
        XCTAssertEqual(try decode(PdfFilterEncoders.lzw(random)), random)
        let flat = [UInt8](repeating: 0, count: 300_000)
        XCTAssertEqual(try decode(PdfFilterEncoders.lzw(flat)), flat)
    }

    func test_wrongEarlyChangeDoesNotMatch() throws {
        let data = FilterFixtures.text(20_000)
        let decoded = try decode(PdfFilterEncoders.lzw(data, true), "<< /EarlyChange 0 >>")
        XCTAssertNotEqual(data, decoded)
    }

    func test_codeBeyondTheTableEndsTheOutput() throws {
        // Clear, a literal, then code 400 which is not in the table.
        var bits: [Bool] = []
        func put(_ code: Int) {
            for i in stride(from: 8, through: 0, by: -1) { bits.append((code >> i & 1) != 0) }
        }
        put(256)
        put(65)
        put(400)
        put(66)
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for i in 0..<bits.count where bits[i] { bytes[i / 8] |= UInt8(0x80 >> (i % 8)) }
        XCTAssertEqual(try decode(bytes), [65])
    }

    func test_missingEndCodeGivesWhatDecoded() throws {
        let data = FilterFixtures.text(1000)
        let encoded = PdfFilterEncoders.lzw(data)
        let decoded = try decode(Array(encoded[..<(encoded.count / 2)]))
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertEqual(Array(data[..<decoded.count]), decoded)
    }

    func test_expansionPastTheCapIsUnsupported() {
        let encoded = PdfFilterEncoders.lzw([UInt8](repeating: 0, count: 2_000_000))
        assertProblem(.unsupported, try PdfFilters.decode(encoded, PdfName("LZW"), nil, 100_000))
    }
}
