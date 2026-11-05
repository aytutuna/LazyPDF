import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/FilterChainTests.cs: the same cases. Assert.Same on a byte array
// (the data comes back untouched) is an equality check here: an array is a value.

final class FilterChainTests: XCTestCase {
    private let plain = FilterFixtures.text(5000)

    func test_noFilterLeavesDataAlone() throws {
        XCTAssertEqual(try PdfFilters.decode(plain, nil, nil), plain)
        XCTAssertEqual(try PdfFilters.decode(plain, PdfNull.instance, nil), plain)
        XCTAssertEqual(try PdfFilters.decode(plain, PdfArray([]), nil), plain)
    }

    func test_chainRunsInOrder() throws {
        // Written as Flate, then ASCII85, so read as ASCII85 first.
        let stored = PdfFilterEncoders.ascii85(PdfFilterEncoders.flate(plain))
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("[/ASCII85Decode /FlateDecode]"), nil), plain)
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("[/A85 /Fl]"), nil), plain)
    }

    func test_eachFilterGetsItsOwnParameters() throws {
        let rowLength = 4
        let rows: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let predicted: [UInt8] = [2, 1, 2, 3, 4, 2, 4, 4, 4, 4]
        let stored = PdfFilterEncoders.asciiHex(PdfFilterEncoders.flate(predicted))
        let parms = try FilterFixtures.parse("[null << /Predictor 12 /Columns \(rowLength) >>]")
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("[/AHx /Fl]"), parms), rows)
    }

    func test_aDictionaryOfParametersGoesToASingleFilter() throws {
        let predicted: [UInt8] = [1, 5, 1, 1]
        let stored = PdfFilterEncoders.flate(predicted)
        let result = try PdfFilters.decode(stored, PdfName("FlateDecode"), try FilterFixtures.parse("<< /Predictor 15 /Columns 3 >>"))
        XCTAssertEqual(result, [5, 6, 7])
    }

    func test_flateNames() throws {
        for name in ["FlateDecode", "Fl"] {
            XCTAssertEqual(try PdfFilters.decode(PdfFilterEncoders.flate(plain), PdfName(name), nil), plain, name)
        }
    }

    func test_lzwNames() throws {
        for name in ["LZWDecode", "LZW"] {
            XCTAssertEqual(try PdfFilters.decode(PdfFilterEncoders.lzw(plain), PdfName(name), nil), plain, name)
        }
    }

    func test_cryptIdentityPassesThrough() throws {
        XCTAssertEqual(try PdfFilters.decode(plain, PdfName("Crypt"), nil), plain)
        XCTAssertEqual(try PdfFilters.decode(plain, PdfName("Crypt"), try FilterFixtures.parse("<< /Type /CryptFilterDecodeParms /Name /Identity >>")), plain)
        let stored = PdfFilterEncoders.flate(plain)
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("[/Crypt /FlateDecode]"), try FilterFixtures.parse("[<< /Name /Identity >> null]")), plain)
    }

    func test_cryptWithAnotherNameIsUnsupported() throws {
        let parms = try FilterFixtures.parse("<< /Name /StdCF >>")
        assertProblem(.unsupported, try PdfFilters.decode(plain, PdfName("Crypt"), parms))
    }

    func test_unknownFilterIsUnsupported() {
        assertProblem(.unsupported, try PdfFilters.decode(plain, PdfName("FooDecode"), nil))
    }

    func test_filterThatIsNotANameIsDamaged() {
        assertProblem(.damaged, try PdfFilters.decode(plain, PdfNumber(3), nil))
    }

    func test_codecIsReportedWithItsInput() throws {
        for (filter, codec) in [("DCTDecode", "DCTDecode"), ("DCT", "DCTDecode"), ("JPXDecode", "JPXDecode"), ("JBIG2Decode", "JBIG2Decode")] {
            let result = try PdfFilters.decodeToCodec(plain, PdfName(filter), nil)
            XCTAssertEqual(result.codec, codec, filter)
            XCTAssertEqual(result.data, plain, filter)
            XCTAssertNil(result.parameters, filter)
        }
    }

    func test_chainStopsAtTheCodecAndKeepsItsParameters() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
        let stored = PdfFilterEncoders.flate(PdfFilterEncoders.ascii85(jpeg))
        let parms = try FilterFixtures.parse("[null null << /ColorTransform 0 >>]")
        let result = try PdfFilters.decodeToCodec(stored, try FilterFixtures.parse("[/Fl /A85 /DCT]"), parms)
        XCTAssertEqual(result.codec, "DCTDecode")
        XCTAssertEqual(result.data, jpeg)
        XCTAssertNotNil(result.parameters)

        let inner = PdfFilterEncoders.flate(jpeg)
        let chained = try PdfFilters.decodeToCodec(inner, try FilterFixtures.parse("[/Fl /DCTDecode]"), try FilterFixtures.parse("[null << /ColorTransform 0 >>]"))
        XCTAssertEqual(chained.data, jpeg)
        XCTAssertEqual((chained.parameters?["ColorTransform"] as? PdfNumber)?.text, "0")
    }

    func test_withoutACodecDecodeToCodecDecodesEverything() throws {
        let result = try PdfFilters.decodeToCodec(PdfFilterEncoders.flate(plain), PdfName("Fl"), nil)
        XCTAssertNil(result.codec)
        XCTAssertEqual(result.data, plain)
    }

    func test_plainDecodeRefusesACodec() {
        assertProblem(.unsupported, try PdfFilters.decode(plain, PdfName("DCTDecode"), nil))
    }

    func test_capAppliesAcrossTheChain() throws {
        let stored = PdfFilterEncoders.ascii85(PdfFilterEncoders.flate([UInt8](repeating: 0, count: 5_000_000)))
        let filter = try FilterFixtures.parse("[/A85 /Fl]")
        assertProblem(.unsupported, try PdfFilters.decode(stored, filter, nil, 1_000_000))
    }

    func test_defaultCapIsOneGibibyte() {
        XCTAssertEqual(PdfFilters.defaultMaxSize, 1 << 30)
    }

    func test_bombThroughTwoFiltersStillStops() throws {
        // Each layer multiplies the size.
        let layer1 = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 10_000_000))
        let layer2 = PdfFilterEncoders.flate(layer1)
        let filter = try FilterFixtures.parse("[/Fl /Fl]")
        assertProblem(.unsupported, try PdfFilters.decode(layer2, filter, nil, 5_000_000))
    }
}
