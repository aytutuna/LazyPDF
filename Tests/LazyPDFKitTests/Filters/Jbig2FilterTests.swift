import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/Jbig2FilterTests.cs, the tests that need no encoder beyond the generic region
// one: the streams of the symbol, text and halftone encoders are the golden files. Left out: the tests that make a symbol
// dictionary or a text region from symbols (a small image sharing a big global dictionary, export runs past the symbols,
// the symbol counts of a dictionary that is coded).
final class Jbig2FilterTests: XCTestCase {
    private let jbig2 = PdfName("JBIG2Decode")

    private func decode(_ stream: [UInt8], _ parameters: PdfObject? = nil, _ maxSize: Int = PdfFilters.defaultMaxSize) throws -> [UInt8] {
        try PdfFilters.decode(stream, jbig2, parameters, maxSize)
    }

    private func whole(_ stream: [UInt8]) throws -> PdfDecodedStream {
        try PdfFilters.decodeToCodecWhole(stream, jbig2, nil, PdfFilters.defaultMaxSize)
    }

    private func unsupported(_ stream: [UInt8], _ parameters: PdfObject? = nil, line: UInt = #line) {
        XCTAssertThrowsError(try decode(stream, parameters), line: line) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .unsupported, line: line) }
    }

    private func damaged(_ stream: [UInt8], line: UInt = #line) {
        XCTAssertThrowsError(try decode(stream), line: line) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged, line: line) }
    }

    private func page(_ width: Int, _ height: Int, _ segments: [UInt8]...) -> [UInt8] {
        Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(width, height)) + segments.flatMap { $0 }
    }

    private func tryDecode(_ data: [UInt8], _ parameters: PdfObject?) {
        _ = try? decode(data, parameters)
    }

    private func seconds(_ since: Date) -> TimeInterval { Date().timeIntervalSince(since) }

    private func sizeParameters(_ width: Int, _ height: Int, globals: [UInt8]? = nil) -> PdfDictionary {
        let parameters = globals.map { Jbig2Samples.parameters($0) } ?? PdfDictionary()
        parameters["Width"] = PdfNumber(width)
        parameters["Height"] = PdfNumber(height)
        return parameters
    }

    func test_globalsComeFirstAndTheImageUsesTheirSymbols() throws {
        let data = try Jbig2Samples.withGlobals()
        let expected = try Jbig2Samples.withGlobalsPage()
        XCTAssertEqual(expected.count, 8 * 40)
        XCTAssertEqual(try decode(data, Jbig2Samples.parameters(try Jbig2Samples.globals())), expected)
        // Without them the text region has nothing to draw.
        XCTAssertThrowsError(try decode(data)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged) }
    }

    func test_imageStreamInAFileReadsItsGlobalsThroughTheDocument() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "", try Jbig2Samples.globals())
        pdf.stream(8, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", try Jbig2Samples.withGlobals())
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertEqual(try document.data(try XCTUnwrap(document.get(8) as? PdfStream)), try Jbig2Samples.withGlobalsPage())
    }

    func test_globalsMayBeFlateCodedAndTheStageMayFollowAnotherFilter() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "/Filter /FlateDecode", TestPdf.deflate(try Jbig2Samples.globals()))
        pdf.stream(8, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter [/FlateDecode /JBIG2Decode] /DecodeParms [null <</JBIG2Globals 7 0 R>>]",
                   TestPdf.deflate(try Jbig2Samples.withGlobals()))
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertEqual(try document.data(try XCTUnwrap(document.get(8) as? PdfStream)), try Jbig2Samples.withGlobalsPage())
    }

    func test_decodeToCodecNoLongerStopsAtJbig2() throws {
        let data = try Jbig2Samples.withGlobals()
        let result = try PdfFilters.decodeToCodec(data, jbig2, Jbig2Samples.parameters(try Jbig2Samples.globals()))
        XCTAssertNil(result.codec)
        XCTAssertEqual(result.data, try Jbig2Samples.withGlobalsPage())
        let kept = try PdfFilters.decodeToCodec(data, jbig2, nil, PdfFilters.defaultMaxSize, keepJbig2: true)
        XCTAssertEqual(kept.codec, "JBIG2Decode")
        XCTAssertEqual(kept.data, data)
    }

    func test_outputIsBoundedByTheSizeLimit() throws {
        let bm = Bm.text(80, 80, 3)
        let stream = Jbig2Segments.generic(bm, 0, false)
        XCTAssertThrowsError(try decode(stream, nil, 500)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .unsupported) }
        XCTAssertEqual(try decode(stream, nil, 800), bm.packed())
    }

    func test_aTinyImageDoesNotGetAHugePageMadeForIt() throws {
        // The page says 11585 by 11585 (134 million pixels, inside the pixel limit); the image it is for is 1 by 1.
        let bm = Bm(8, 8)
        let stream = Jbig2Segments.cat(Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(11585, 11585)),
                                       Jbig2Segments.segment(1, 38, Jbig2Segments.genericData(bm, [0xff, 0xac], 0, false, false, nil)))
        let start = Date()
        unsupported(stream, sizeParameters(1, 1))
        XCTAssertLessThan(seconds(start), 2)
        // A page of a normal size for its picture still decodes.
        let big = Bm.text(100, 100, 2)
        XCTAssertEqual(try decode(Jbig2Segments.generic(big, 0, false), sizeParameters(100, 100)), big.packed())
    }

    func test_moreSegmentsThanTheLimitAreRefused() {
        let empty = Jbig2Segments.segment(1, 62, [])
        var segments = [Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(8, 8))]
        for _ in 0..<70000 { segments.append(empty) }
        unsupported(segments.flatMap { $0 })
    }

    func test_pageOverTheSizeLimitIsRefusedBeforeItIsMade() {
        // 30000 by 30000 is 112 MB of pixels, inside the pixel limit, but its rows are 113 MB: past a limit of a megabyte.
        XCTAssertThrowsError(try decode(page(30000, 30000), nil, 1 << 20)) {
            let e = $0 as? PdfReadException
            XCTAssertEqual(e?.problem, .unsupported)
            XCTAssertEqual(e?.message, FilterBuffer.tooBig().message)
        }
    }

    func test_pagesAndRegionsOverThePixelLimitAreRefusedBeforeAnythingIsMade() {
        unsupported(page(Int(Int32.max), 5))
        unsupported(page(20000, 20000))
        unsupported(page(0x7fffffff, 0x7fffffff))
        // A region far bigger than the page, in a stream that is a few bytes long.
        let bm = Bm(4, 4)
        let e = ArithEncoder()
        Jbig2Encode.generic(e, bm, 0, false)
        var data = Jbig2Segments.genericData(bm, e.finish(), 0, false, false, nil)
        data.replaceSubrange(0..<4, with: Jbig2Segments.u32(100000))
        data.replaceSubrange(4..<8, with: Jbig2Segments.u32(100000))
        unsupported(page(10, 10, Jbig2Segments.segment(1, 38, data)))
    }

    func test_manyMediumRegionsRunOutOfTheMemoryBudget() {
        // Each region is within the limit and the stream is small, but together they ask for more than a decode may make.
        // MMR data that ends at once leaves the rest of the region white, so every region is quick.
        var data = Jbig2Segments.genericData(Bm(4, 4), [], 0, true, false, nil)
        data.replaceSubrange(0..<4, with: Jbig2Segments.u32(11000))
        data.replaceSubrange(4..<8, with: Jbig2Segments.u32(11000))
        var segments = [Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(8, 8))]
        for i in 1...8 { segments.append(Jbig2Segments.segment(i, 38, data)) }
        unsupported(segments.flatMap { $0 })
    }

    func test_stripedPageThatReachesFarDownIsRefused() {
        let bm = Bm(10, 4)
        let e = ArithEncoder()
        Jbig2Encode.generic(e, bm, 0, false)
        let data = Jbig2Segments.genericData(bm, e.finish(), 0, false, false, nil, y: 0x7ffffff0)
        unsupported(Jbig2Segments.cat(Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(10, -1)), Jbig2Segments.segment(1, 38, data)))
        unsupported(Jbig2Segments.cat(Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(10, -1)), Jbig2Segments.segment(1, 50, Jbig2Segments.u32(0x7ffffff0))))
    }

    func test_symbolCountsAndInstanceCountsAreCapped() {
        // A dictionary that says it holds a billion symbols.
        let dictionary = Jbig2Segments.cat(Jbig2Segments.u16(0), Jbig2Segments.at([3, -1, -3, -1, 2, -2, -2, -2]),
                                           Jbig2Segments.u32(1_000_000_000), Jbig2Segments.u32(1_000_000_000), [0xff, 0xac])
        unsupported(page(10, 10, Jbig2Segments.segment(1, 0, dictionary)))

        // A text region with 4 billion instances: the count is read before anything else is looked at.
        let text = Jbig2Segments.cat(Jbig2Segments.regionInfo(20, 20), Jbig2Segments.u16(0), Jbig2Segments.u32(0xffffffff), [0xff, 0xac])
        unsupported(page(20, 20, Jbig2Segments.segment(2, 6, text)))
    }

    func test_impossibleSegmentHeadersAreDamage() {
        // A long form count of 0x1FFFFFFF referred segments in a header that ends there.
        damaged(Jbig2Segments.cat(Jbig2Segments.u32(1), [0x28], Jbig2Segments.u32(0xffffffff)))
        // A short form count of 5, which only the long form may have.
        damaged(Jbig2Segments.cat(Jbig2Segments.u32(1), [0x28, 0xa0], [1, 2, 3, 4, 5], [1], Jbig2Segments.u32(0)))
        // No length on a segment that must have one.
        damaged(Jbig2Segments.cat(Jbig2Segments.u32(1), [0x30, 0x00, 0x01], Jbig2Segments.u32(0xffffffff)))
        // A region before the page, and a stream without a page.
        damaged(Jbig2Segments.segment(1, 38, Jbig2Segments.genericData(Bm(2, 2), [0xff, 0xac], 0, false, false, nil)))
        damaged([])
    }

    func test_segmentsThatCannotBeDecodedAreLeftOutAndTheRestIsKept() throws {
        let bm = Bm.text(30, 20, 7)
        let e = ArithEncoder()
        Jbig2Encode.generic(e, bm, 0, false)
        // A text region that refers to a symbol dictionary that is not there, between two good segments.
        let text = Jbig2Segments.cat(Jbig2Segments.regionInfo(30, 20), [UInt8](repeating: 0, count: 16))
        let stream = page(30, 20, Jbig2Segments.segment(1, 6, text, [9]),
                          Jbig2Segments.segment(2, 38, Jbig2Segments.genericData(bm, e.finish(), 0, false, false, nil)))
        XCTAssertEqual(try decode(stream), bm.packed())
    }

    func test_manyRegionsThatFailForAFailedDictionaryDoNotEndAPartialDecode() throws {
        // One symbol dictionary that does not decode, 17 text regions that use it, and a region that is fine after them.
        let bm = Bm.text(8, 8, 3)
        let e = ArithEncoder()
        Jbig2Encode.generic(e, bm, 0, false)
        var segments = [Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(8, 8)), Jbig2Segments.segment(1, 0, [UInt8](repeating: 0, count: 12))]
        for i in 0..<17 { segments.append(Jbig2Segments.segment(2 + i, 6, [UInt8](repeating: 0, count: 20), [1])) }
        segments.append(Jbig2Segments.segment(30, 38, Jbig2Segments.genericData(bm, e.finish(), 0, false, false, nil)))
        let stream = segments.flatMap { $0 }
        XCTAssertEqual(try decode(stream), bm.packed())
        XCTAssertThrowsError(try whole(stream)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged) }
    }

    func test_cutAndDamagedStreamsGiveAnErrorOrWhatDecodedAndNeverHang() throws {
        let start = Date()
        let names = try Jbig2Samples.names()
        let samples = try names.map { try Jbig2Samples.file($0) }
        let globals = Jbig2Samples.parameters(try Jbig2Samples.globals())
        for sample in samples {
            var length = 0
            while length < sample.count {
                tryDecode(Array(sample[..<length]), globals)
                length += max(1, sample.count / 30)
            }
        }
        var random = DotNetRandom(77)
        for _ in 0..<12 {
            for sample in samples {
                var data = sample
                var flips = random.next(1, 4)
                while flips > 0 {
                    data[random.next(data.count)] ^= UInt8(1 << random.next(8))
                    flips -= 1
                }
                tryDecode(data, globals)
            }
        }
        XCTAssertLessThan(seconds(start), 10)
    }

    func test_segmentsOfEveryLengthUnderTheirMinimumNeverRaiseAnythingButDamage() {
        let types = [0, 4, 6, 7, 16, 20, 22, 23, 36, 38, 39, 40, 42, 43, 48, 50, 53]
        for type in types {
            for length in 0...45 {
                for fill in [0x00, 0x01, 0x03, 0x80, 0xff] as [UInt8] {
                    let body = [UInt8](repeating: fill, count: length)
                    tryDecode(page(8, 8, Jbig2Segments.segment(1, type, body), [UInt8](repeating: fill, count: 60)), PdfDictionary())
                    tryDecode(page(8, 8, Jbig2Segments.segment(1, type, body, [0, 0, 0])), nil)
                }
            }
        }
    }

    func test_aSegmentCutShortIsDamageEvenWithBytesAfterIt() {
        // The bytes after the segment must not be read as part of it: a generic region of 17 bytes followed by a byte with bit 0 set
        // is an MMR region with no data, a pattern dictionary of 3 bytes has no sizes, a halftone region of 20 has no grid.
        let cases: [(type: Int, length: Int, fill: UInt8)] = [(38, 17, 1), (38, 17, 0), (16, 3, 1), (22, 20, 1), (6, 18, 0), (0, 1, 0), (42, 17, 3)]
        for c in cases {
            damaged(page(8, 8, Jbig2Segments.segment(1, c.type, [UInt8](repeating: c.fill, count: c.length)), [UInt8](repeating: c.fill, count: 40)))
        }
    }

    func test_paddingAfterTheLastSegmentIsTheEndOfTheData() throws {
        for tail in ["\r\n", "\0\0\0", "A", String(repeating: "\0", count: 20)] {
            let bm = Bm.text(30, 20, 5)
            let stream = Jbig2Segments.generic(bm, 0, false) + TestPdf.latin(tail)
            XCTAssertEqual(try whole(stream).data, bm.packed(), tail)
        }
    }

    func test_aLongRunOfZerosBeforeALastByteIsGivenUpOnQuickly() {
        // What a Flate stage can make of a few hundred kilobytes: megabytes of zero headers and a byte at the end that is not zero.
        let stream = page(8, 8) + [UInt8](repeating: 0, count: 8 << 20) + [1]
        let start = Date()
        damaged(stream)
        XCTAssertLessThan(seconds(start), 2)
    }

    // The bits as bytes, the last one padded with zeros.
    private func bits(_ text: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (text.count + 7) / 8)
        for (i, c) in text.enumerated() where c == "1" { bytes[i / 8] |= UInt8(0x80 >> (i % 8)) }
        return bytes
    }

    func test_aHeightClassOfNoWidthButGreatHeightIsRefusedAtOnce() {
        // A Huffman coded dictionary of one symbol: height 2^30 (Table B.4, last line), width 0 (B.2), the end of the class, a bitmap size of 0 (B.1).
        let offset = String((1 << 30) - 76, radix: 2)
        let text = "11111" + String(repeating: "0", count: 32 - offset.count) + offset + "0" + "111111" + "00000"
        let data = Jbig2Segments.cat(Jbig2Segments.u16(1), Jbig2Segments.u32(1), Jbig2Segments.u32(1), bits(text))
        let start = Date()
        unsupported(page(10, 10, Jbig2Segments.segment(1, 0, data)))
        XCTAssertLessThan(seconds(start), 2)
    }

    func test_aFitOfAnyHugeSizeNeverMakesTheBudgetNegative() throws {
        let budget = Jbig2Budget()
        budget.forImage(1 << 62)
        try budget.charge(8, 8)
        try budget.chargeWork(1000)
        // Through the filter: the page is made, and what is refused is the size of the rows the image asks for.
        let parameters = sizeParameters(Int(Int32.max), Int(Int32.max))
        XCTAssertThrowsError(try decode(Jbig2Segments.generic(Bm(1, 1), 0, false), parameters)) {
            let e = $0 as? PdfReadException
            XCTAssertEqual(e?.problem, .unsupported)
            XCTAssertEqual(e?.message, FilterBuffer.tooBig().message)
        }
    }

    func test_globalsHoldDictionariesAndTablesAndNothingElse() throws {
        // A region of 134 million pixels in the globals is not drawn, and costs nothing, for an image of one pixel.
        var region = Jbig2Segments.genericData(Bm(4, 4), [0xff, 0xac], 0, false, false, nil)
        region.replaceSubrange(0..<4, with: Jbig2Segments.u32(11585))
        region.replaceSubrange(4..<8, with: Jbig2Segments.u32(11585))
        let globals = Jbig2Segments.segment(1, 36, region, page: 0)
        let parameters = sizeParameters(8, 8, globals: globals)
        let start = Date()
        let bm = Bm.text(8, 8, 3)
        XCTAssertEqual(try decode(Jbig2Segments.generic(bm, 0, false), parameters), bm.packed())
        XCTAssertLessThan(seconds(start), 2)
    }

    func test_aCutSegmentIsOnlyAFailureWhenThePageMustBeWhole() throws {
        let sample = try Jbig2Samples.file("generic-t0.bin")
        let cut = Array(sample.dropLast(6))
        _ = try decode(cut)
        XCTAssertThrowsError(try whole(cut)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged) }
    }

    func test_nothingAfterTheEndOfThePageIsRead() throws {
        let bm = Bm.text(30, 20, 5)
        let stream = Jbig2Segments.generic(bm, 0, false) + Jbig2Segments.segment(5, 49, []) + [UInt8](repeating: 0x7f, count: 25)
        XCTAssertEqual(try whole(stream).data, bm.packed())
    }

    func test_huffmanTablesThatDoNotFitAreDamage() {
        // Prefix lengths of 1 for three values cannot all be codes.
        XCTAssertThrowsError(try Jbig2Huffman([(0, 1, 0, 0), (1, 1, 0, 0), (2, 1, 0, 0)]))
        XCTAssertThrowsError(try Jbig2Huffman([(0, 40, 0, 0)]))
        // A table segment of 32 bit ranges that never reaches its upper end ends with the data.
        let segment: [UInt8] = [0, 0x80, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0x12, 0x34]
        XCTAssertThrowsError(try Jbig2Huffman.custom(segment, 0, segment.count))
    }

    func test_aRunOfInstancesPastTheEndOfTheDataStillEnds() throws {
        // A real region of one instance over a real dictionary, whose count is then made the most there may be: the data runs
        // out after the first instance and the decoder keeps going on the ones it is fed.
        let symbol = Bm.text(3, 3, 4)
        let dictionary = Jbig2Segments.segment(1, 0, Jbig2Encode.oneSymbolDictionary(symbol))
        var text = Jbig2Encode.oneInstanceText(10, 10, x: 2, y: 3)
        let one = page(10, 10, dictionary, Jbig2Segments.segment(2, 6, text, [1]))
        let placed = Bm(10, 10)
        for y in 0..<3 { for x in 0..<3 { placed[2 + x, 3 + y] = symbol[x, y] } }
        XCTAssertEqual(try decode(one), placed.packed())

        text.replaceSubrange(19..<23, with: Jbig2Segments.u32(Jbig2Text.maxInstances))
        let stream = page(10, 10, dictionary, Jbig2Segments.segment(2, 6, text, [1]))
        let start = Date()
        // The picture the region is for is 10 by 10, which is what the work a decode may do is measured by. The one instance that
        // is coded decodes as above (so the first pass of the loop is made); the loop then asks for more, and the data that is
        // left is where the decode ends, as damage, in the second pass: a strip delta that is out of band where there is none.
        XCTAssertThrowsError(try decode(stream, sizeParameters(10, 10))) { error in
            let e = error as? PdfReadException
            XCTAssertEqual(e?.problem, .damaged)
            XCTAssertEqual(e?.message, "A JBIG2 text region has an out-of-band value where there is none.")
        }
        XCTAssertLessThan(seconds(start), 3)
    }
}
