import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ContentParserTests.cs: the same cases. BinaryJunkDoesNotThrow draws its
// bytes from the seeded generator the font tests use, not System.Random.

final class ContentParserTests: XCTestCase {
    private func parse(_ text: String) -> [ContentOperation] { ContentTestPdf.parse(text) }

    private func latin(_ text: String) -> [UInt8] { ContentTestPdf.latin(text) }

    private func slice(_ text: String, _ start: Int, _ end: Int) -> String {
        Latin1.string(Array(latin(text)[start..<end]))
    }

    func test_operandsGoWithTheirOperator() throws {
        let ops = parse("q 1 0 0 1 10 20 cm /F1 12 Tf (Hi) Tj Q")
        XCTAssertEqual(ops.map { $0.operator }, ["q", "cm", "Tf", "Tj", "Q"])
        XCTAssertEqual(ops[1].operands.count, 6)
        XCTAssertEqual(ops[1].number(5), 20)
        XCTAssertEqual((ops[2].operands[0] as? PdfName)?.value, "F1")
        XCTAssertEqual(Latin1.string(try XCTUnwrap(ops[3].operands[0] as? PdfString).bytes), "Hi")
    }

    func test_positionsCoverOperandsAndOperator() {
        let text = "q  10 20 m % comment\n 30 40 l S Q"
        let ops = parse(text)
        XCTAssertEqual(slice(text, ops[1].start, ops[1].end), "10 20 m")
        XCTAssertEqual(slice(text, ops[2].start, ops[2].end), "30 40 l")
        XCTAssertEqual(slice(text, ops[3].start, ops[3].end), "S")
    }

    func test_oddNumbersReadAsAViewerReadsThem() throws {
        for (content, text) in [("--5 w", "-5"), ("-.5 w", "-.5"), ("4. w", "4."), ("+3 w", "+3"), ("- w", "0"), (". w", "0")] {
            let op = parse(content)[0]
            XCTAssertEqual(op.operator, "w", content)
            XCTAssertEqual((op.operands[0] as? PdfNumber)?.text, text, content)
        }
    }

    func test_joinedNumbersSplit() {
        let ops = parse("1.2.3 5-3 m")
        XCTAssertEqual(ops[0].operands.map { ($0 as? PdfNumber)?.text }, ["1.2", ".3", "5", "-3"])
    }

    func test_stringsEscapesAndHex() throws {
        let ops = parse("(a\\(b\\)\\101\\n\\\nc(nested)) Tj <48656C6C6F2> Tj")
        XCTAssertEqual(Latin1.string(try XCTUnwrap(ops[0].operands[0] as? PdfString).bytes), "a(b)A\nc(nested)")
        let hex = try XCTUnwrap(ops[1].operands[0] as? PdfString)
        XCTAssertTrue(hex.isHex)
        XCTAssertEqual(Latin1.string(hex.bytes), "Hello ")
    }

    func test_namesDecodeEscapes() {
        let op = parse("/A#20B gs")[0]
        XCTAssertEqual((op.operands[0] as? PdfName)?.value, "A B")
    }

    func test_arraysAndDictionariesNest() throws {
        let ops = parse("[(A) -120 (B) [1 2]] TJ /OC <</MCID 3 /K [/A <</X 1>>]>> BDC")
        let array = try XCTUnwrap(ops[0].operands[0] as? PdfArray)
        XCTAssertEqual(array.items.count, 4)
        let dictionary = try XCTUnwrap(ops[1].operands[1] as? PdfDictionary)
        XCTAssertEqual((dictionary["MCID"] as? PdfNumber)?.value, 3)
    }

    func test_booleansAndNullAreOperands() {
        let op = parse("true false null foo")[0]
        XCTAssertEqual(op.operator, "foo")
        XCTAssertEqual(op.operands.count, 3)
    }

    func test_unknownOperatorsStayAndClearOperands() {
        let ops = parse("1 2 3 zork 4 w")
        XCTAssertEqual(ops.map { $0.operator }, ["zork", "w"])
        XCTAssertEqual(ops[1].operands.count, 1)
    }

    func test_strayDelimitersAreSkipped() {
        let ops = parse(") ] >> } 1 w >")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].operator, "w")
    }

    func test_anUnclosedArrayEndsAtTheNextOperator() throws {
        let ops = parse("BT [(A) 10 (B) TJ ET")
        XCTAssertEqual(ops.map { $0.operator }, ["BT", "TJ", "ET"])
        XCTAssertEqual(try XCTUnwrap(ops[1].operands[0] as? PdfArray).items.count, 3)
    }

    func test_anUnclosedStringOrHexRunsToTheEnd() {
        XCTAssertTrue(parse("(never closed Tj").isEmpty)
        XCTAssertTrue(parse("<4142 Tj").isEmpty)
    }

    func test_deepNestingIsCut() {
        let deep = String(repeating: "[", count: 100000) + "1 w"
        XCTAssertFalse(ContentTestPdf.parse(deep).isEmpty)
    }

    func test_tooManyOperandsAreDropped() {
        let ops = parse(Array(repeating: "1", count: 5000).joined(separator: " ") + " w")
        XCTAssertLessThanOrEqual(ops[0].operands.count, 512)
    }

    func test_binaryJunkDoesNotThrow() {
        var random = ProgramFonts.Random(7)
        for _ in 0..<50 {
            let bytes = (0..<2000).map { _ in UInt8(random.next(256)) }
            _ = ContentParser.parse(bytes)
        }
    }

    func test_inlineImageWithUnfilteredDataUsesItsLength() throws {
        // The data holds "EI" in the middle, as raw samples may.
        let data: [UInt8] = [0x00, 0x20, 0x45, 0x49, 0x20, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0]
        let bytes = latin("q BI /W 4 /H 3 /BPC 8 /CS /G ID ") + data + latin("\nEI Q")
        let ops = ContentParser.parse(bytes)
        XCTAssertEqual(ops.map { $0.operator }, ["q", "BI", "Q"])
        XCTAssertEqual(try XCTUnwrap(ops[1].image).data, data)
        XCTAssertEqual((try XCTUnwrap(ops[1].image).dictionary["W"] as? PdfNumber)?.value, 4)
    }

    func test_inlineImageWithAFilterFindsEiByWhatFollows() throws {
        // Binary data with a stray " EI " followed by non-text bytes, then the real end.
        let data: [UInt8] = [1, 2, 3, 0x20, 0x45, 0x49, 0x20, 0xFF, 0xFE, 0xFD, 9, 8, 7]
        let bytes = latin("BI /W 2 /H 2 /F /Fl /CS /RGB /BPC 8 ID\n") + data + latin("\nEI\n1 w")
        let ops = ContentParser.parse(bytes)
        XCTAssertEqual(ops.map { $0.operator }, ["BI", "w"])
        XCTAssertEqual(try XCTUnwrap(ops[0].image).data, data)
    }

    func test_inlineImageEndsAtTheEndOfDataWithoutEi() {
        let ops = parse("BI /W 1 /H 1 /F /AHx ID 00>")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].operator, "BI")
    }

    func test_inlineImageWithCrLfAfterId() throws {
        let bytes = latin("BI /W 1 /H 1 /BPC 8 /CS /G ID\r\n") + [7] + latin("\nEI")
        let ops = ContentParser.parse(bytes)
        XCTAssertEqual(try XCTUnwrap(ops[0].image).data, [7])
    }

    func test_expandedInlineDictionaryUsesFullKeys() throws {
        let image = try XCTUnwrap(parse("BI /W 1 /H 1 /BPC 8 /CS /Cs1 /F /Fl ID x\nEI")[0].image)
        let expanded = image.expanded { _ in PdfName("DeviceRGB") }
        XCTAssertNotNil(expanded["Width"])
        XCTAssertNotNil(expanded["Filter"])
        XCTAssertEqual((expanded["ColorSpace"] as? PdfName)?.value, "DeviceRGB")
    }

    func test_largeStreamParsesQuickly() {
        var text = ""
        for _ in 0..<200000 { text += "BT /F1 10 Tf 1 0 0 1 10 20 Tm (Hello) Tj ET\n" }
        let started = Date()
        let ops = ContentTestPdf.parse(text)
        XCTAssertEqual(ops.count, 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "\(Date().timeIntervalSince(started)) s")
    }

    // No C# twin: the Swift parser indexes arrays, so every cut of a stream that holds each construct is parsed.
    func test_everyPrefixOfARichStreamParses() {
        let text = "q 1 0 0 1 10 20 cm /F1 12 Tf (a\\(b\\)\\101\\n) Tj <48656C6C6F2> Tj [(A) -120 (B) [1 2]] TJ "
            + "/OC <</MCID 3 /K [/A <</X 1>>]>> BDC BI /W 2 /H 2 /BPC 8 /CS /G ID abcd\nEI EMC --5 .5. - w Q "
            + "BI /W 72057594037927928 /H 1024 /IM true ID xx EI"
        let bytes = latin(text)
        for cut in 0...bytes.count { _ = ContentParser.parse(Array(bytes[0..<cut])) }
    }
}
