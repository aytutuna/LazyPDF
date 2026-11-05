import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/AsciiFilterTests.cs: the same cases.

final class AsciiFilterTests: XCTestCase {
    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private func decode(_ filter: String, _ data: [UInt8]) throws -> [UInt8] {
        try PdfFilters.decode(data, PdfName(filter), nil)
    }

    func test_hexIgnoresSpaceAndStopsAtTheMarker() throws {
        XCTAssertEqual(try decode("ASCIIHexDecode", ascii("48 65\n6c6C\t6F>junk")), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
    }

    func test_hexOddLastDigitIsPaddedWithZero() throws {
        XCTAssertEqual(try decode("AHx", ascii("ABC>")), [0xAB, 0xC0])
    }

    func test_hexWithoutMarkerDecodesToTheEnd() throws {
        XCTAssertEqual(try decode("AHx", ascii("0102")), [0x01, 0x02])
    }

    func test_hexWithAStrayCharacterIsDamaged() {
        assertProblem(.damaged, try decode("AHx", ascii("12G4>")))
    }

    func test_hexEncoderRoundTrips() throws {
        let data = FilterFixtures.randomBytes(1000)
        let encoded = PdfFilterEncoders.asciiHex(data)
        XCTAssertEqual(encoded.last, UInt8(ascii: ">"))
        XCTAssertEqual(try decode("AHx", encoded), data)
    }

    func test_ascii85KnownAnswer() throws {
        XCTAssertEqual(string(try decode("ASCII85Decode", ascii("9jqo^BlbD-BleB1DJ+*+F(f,q~>"))), "Man is distinguished")
        XCTAssertEqual(PdfFilterEncoders.ascii85(ascii("Man is distinguished")), ascii("9jqo^BlbD-BleB1DJ+*+F(f,q~>"))
    }

    func test_ascii85ZStandsForFourZeroBytes() throws {
        XCTAssertEqual(try decode("A85", ascii("zz~>")), [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(PdfFilterEncoders.ascii85([UInt8](repeating: 0, count: 4)), ascii("z~>"))
    }

    func test_ascii85AcceptsThePrefixAndWhiteSpace() throws {
        XCTAssertEqual(string(try decode("A85", ascii("<~9jq\n o^~>"))), "Man ")
    }

    func test_ascii85WithoutTheEndMarkerDecodesToTheEnd() throws {
        XCTAssertEqual(string(try decode("A85", ascii("9jqo^"))), "Man ")
    }

    func test_ascii85OutsideTheAlphabetIsDamaged() {
        assertProblem(.damaged, try decode("A85", ascii("9jq{o^~>")))
    }

    func test_ascii85RoundTripsEveryTailLength() throws {
        for length in [0, 1, 2, 3, 4, 5, 1001] {
            let data = FilterFixtures.randomBytes(length, length + 1)
            XCTAssertEqual(try decode("A85", PdfFilterEncoders.ascii85(data)), data, "length \(length)")
        }
    }

    func test_runLengthDecodes() throws {
        // Three literal bytes, four copies of 7, end of data, then bytes that must not be read.
        let encoded: [UInt8] = [2, 10, 20, 30, 253, 7, 128, 0, 99]
        XCTAssertEqual(try decode("RunLengthDecode", encoded), [10, 20, 30, 7, 7, 7, 7])
    }

    func test_runLengthCutShortGivesWhatIsThere() throws {
        XCTAssertEqual(try decode("RL", [4, 1, 2]), [1, 2])
        XCTAssertEqual(try decode("RL", [0, 1, 250]), [1])
    }

    func test_runLengthEncoderRoundTrips() throws {
        var mixed: [UInt8] = []
        mixed += FilterFixtures.randomBytes(300, 2)
        mixed += [UInt8](repeating: 0, count: 500)
        mixed += FilterFixtures.randomBytes(130, 4)
        mixed += [UInt8](repeating: 9, count: 129)
        mixed.append(5)
        let cases: [[UInt8]] = [mixed, [], [1], [1, 1], [1, 2, 2], [UInt8](repeating: 0, count: 128), [UInt8](repeating: 0, count: 129)]
        for data in cases {
            XCTAssertEqual(try decode("RunLengthDecode", PdfFilterEncoders.runLength(data)), data)
        }
    }

    func test_runLengthShrinksRuns() {
        XCTAssertLessThan(PdfFilterEncoders.runLength([UInt8](repeating: 0, count: 10_000)).count, 200)
    }

    func test_runLengthBombStopsAtTheCap() {
        let packed = PdfFilterEncoders.runLength([UInt8](repeating: 0, count: 1_000_000))
        assertProblem(.unsupported, try PdfFilters.decode(packed, PdfName("RL"), nil, 10_000))
    }
}
