import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ContentWriterTests.cs: the same cases. NumbersAreShortAndInvariant does
// not switch the thread's culture to tr-TR: Swift's number formatting has no culture to switch.

final class ContentWriterTests: XCTestCase {
    private func text(_ w: ContentWriter) -> String { Latin1.string(w.toArray()) }

    private func describe(_ ops: [ContentOperation]) -> String {
        var parts: [String] = []
        for o in ops {
            var part = o.operator + ":" + o.operands.map { $0.description }.joined(separator: ",")
            if let image = o.image { part += "#" + image.data.map { String(format: "%02X", $0) }.joined() }
            parts.append(part)
        }
        return parts.joined(separator: "|")
    }

    func test_parseThenWriteGivesTheSameOperations() {
        for content in [
            "q 1 0 0 1 10 20.5 cm /F1 12 Tf (a\\(b\\)\\n) Tj <00FF> Tj [(A) -120 (B)] TJ Q",
            "/Span <</MCID 3 /Lang (en)>> BDC EMC [3 2] 1 d 0.5 g 0 0 100 100 re f*",
            "BT 1 0 0 1 5 5 Tm (x) ' 1 2 (y) \" ET",
            "1 2 zork 3 4 w true false null foo",
        ] {
            let first = ContentTestPdf.parse(content)
            let second = ContentParser.parse(ContentWriter.write(first))
            XCTAssertEqual(describe(second), describe(first), content)
        }
    }

    func test_inlineImagesSurviveARoundTripEvenWithBinaryData() throws {
        let data: [UInt8] = [0, 1, 2, 0x20, 0x45, 0x49, 0x20, 0xFF, 0xFE, 0x80, 10, 13, 40, 41]
        let bytes = ContentTestPdf.latin("q BI /W 14 /H 1 /BPC 8 /CS /G ID ") + data + ContentTestPdf.latin("\nEI Q")
        let first = ContentParser.parse(bytes)
        let second = ContentParser.parse(ContentWriter.write(first))
        XCTAssertEqual(second.map { $0.operator }, ["q", "BI", "Q"])
        XCTAssertEqual(try XCTUnwrap(second[1].image).data, data)
    }

    func test_roundTripOfARealPage() {
        let content = ContentTestPdf.latin(String(repeating: "BT /F1 10 Tf 1 0 0 1 72 700 Tm [(Hello) -250 (World)] TJ ET\n0.2 0.4 0.6 rg 10 10 50 50 re f\n", count: 200))
        let first = ContentParser.parse(content)
        let second = ContentParser.parse(ContentWriter.write(first))
        XCTAssertEqual(describe(second), describe(first))
    }

    func test_numbersAreShortAndInvariant() {
        let w = ContentWriter().op("m", 0.1 + 0.2, 1e-9, -0.0, 12345678, 1.5, 2.0 / 3)
        XCTAssertEqual(text(w), "0.3 0 0 12345678 1.5 0.666667 m\n")
        XCTAssertEqual(text(ContentWriter().lineTo(1.5, 0)), "1.5 0 l\n")
    }

    func test_helpersWriteTheOperatorsTheyAreNamedFor() {
        let w = ContentWriter()
            .save().concat(PdfMatrix(1, 0, 0, 1, 10, 20)).fillRgb(1, 0, 0).rect(0, 0, 50, 40).fill().restore()
            .beginText().font("F1", 12).moveText(72, 700).show(Array("Hi".utf8)).endText()
            .paint("Im1", PdfMatrix(100, 0, 0, 50, 0, 0))
            .beginMarked("Span", 7).endMarked()
        XCTAssertEqual(
            text(w),
            "q\n1 0 0 1 10 20 cm\n1 0 0 rg\n0 0 50 40 re\nf\nQ\nBT\n/F1 12 Tf\n72 700 Td\n<4869> Tj\nET\nq\n100 0 0 50 0 0 cm\n/Im1 Do\nQ\n/Span <</MCID 7>> BDC\nEMC\n")
    }

    func test_builtContentParsesBackAndRuns() throws {
        let w = ContentWriter().save().fillRgb(0, 0, 1).rect(10, 10, 20, 20).fill().restore()
            .beginText().font("F1", 10).moveText(50, 60).show(Array("AB".utf8)).endText()
        let document = try ContentTestPdf.page(w.toArray(), "/Font <</F1 5 0 R>>", [ContentTestPdf.helvetica])
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.text, "AB")
        XCTAssertEqual(r.paths[0].path.bounds, PdfRect(10, 10, 30, 30))
        XCTAssertEqual(r.paths[0].state.fillColor.rgb, RgbColor(0, 0, 255))
    }

    func test_rawAddsALine() {
        XCTAssertEqual(text(ContentWriter().raw("1 w")), "1 w\n")
    }

    func test_aCutRangeCanBeRemovedByPosition() throws {
        let source = "BT /F1 10 Tf (secret) Tj (keep) Tj ET"
        let ops = ContentTestPdf.parse(source)
        let target = try XCTUnwrap(ops.first { $0.operator == "Tj" })
        let bytes = Array(source.utf8)
        let edited = Array(bytes[..<target.start]) + Array(bytes[target.end...])
        XCTAssertEqual(String(decoding: edited, as: UTF8.self), "BT /F1 10 Tf  (keep) Tj ET")
    }
}
