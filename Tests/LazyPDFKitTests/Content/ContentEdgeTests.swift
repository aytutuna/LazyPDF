import XCTest
@testable import LazyPDFKit

// No C# twin. The C# reaches ShowPatch, PageAppearances and the font program checks (canDraw, programWidth,
// programCidWidth, glyphNameOf) only through the editing, redaction and standards layers; these cases run them here,
// with the positions Int.max, Int.min and -1 where a reader takes a position or a glyph.

final class ContentEdgeTests: XCTestCase {
    private func font(_ d: PdfDocument, _ number: Int) throws -> PdfFont {
        PdfFont.get(d, try XCTUnwrap(d.get(number) as? PdfDictionary))
    }

    private func simple() throws -> PdfDocument {
        let bytes = try SyntheticFonts.ttf()
        return try ContentTestPdf.page("", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R>>")
            pdf.obj(6, "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontFile2 7 0 R>>")
            pdf.stream(7, "", bytes)
        }
    }

    private func composite(_ map: String = "/Identity", _ mapData: [UInt8] = []) throws -> PdfDocument {
        let bytes = try SyntheticFonts.ttf()
        return try ContentTestPdf.page("", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [6 0 R]>>")
            let to = mapData.isEmpty ? map : "9 0 R"
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor 7 0 R /CIDToGIDMap \(to)>>")
            pdf.obj(7, "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontFile2 8 0 R>>")
            pdf.stream(8, "", bytes)
            if !mapData.isEmpty { pdf.stream(9, "", mapData) }
        }
    }

    private func char(_ code: Int, _ cid: Int, _ unicode: String?) -> FontChar {
        FontChar(code: code, length: 1, cid: cid, width: 0, unicode: unicode, isSpace: false,
                 verticalAdvance: 0, originX: 0, originY: 0)
    }

    private func gidOfA() throws -> Int {
        try XCTUnwrap(TrueTypeFont.tryParse(try SyntheticFonts.ttf())).glyphForCodePoint(0x41)
    }

    func test_canDrawAsksTheProgramOfASimpleFont() throws {
        let f = try font(try simple(), 5)
        XCTAssertTrue(f.isEmbedded)
        XCTAssertTrue(f.canDraw(char(65, 65, "A")))
        XCTAssertTrue(f.canDraw(char(32, 32, " ")))
        XCTAssertFalse(f.canDraw(char(122, 122, "z")))
        XCTAssertTrue(f.canDraw(char(300, 300, " ")))
        for code in [300, -1, Int.max, Int.min] { XCTAssertFalse(f.canDraw(char(code, code, "x")), "\(code)") }
    }

    func test_canDrawIsTrueForAFontWithoutAProgram() throws {
        let d = try ContentTestPdf.page("", "", [ContentTestPdf.helvetica])
        XCTAssertTrue(try font(d, 5).canDraw(char(65, 65, "A")))
    }

    func test_canDrawAsksTheProgramOfACompositeFont() throws {
        let f = try font(try composite(), 5)
        let gid = try gidOfA()
        XCTAssertGreaterThan(gid, 0)
        XCTAssertTrue(f.canDraw(char(0, gid, "A")))
        XCTAssertFalse(f.canDraw(char(0, 0, "x")))
        XCTAssertTrue(f.canDraw(char(0, 0, " ")))
        for cid in [-1, Int.max, Int.min] { XCTAssertFalse(f.canDraw(char(0, cid, "x")), "\(cid)") }
    }

    func test_glyphNameOfAndProgramWidthTakeOnlyCodesOfASimpleFont() throws {
        let d = try simple()
        let f = try font(d, 5)
        XCTAssertEqual(f.glyphNameOf(65), "A")
        XCTAssertGreaterThan(try XCTUnwrap(f.programWidth(65)), 0)
        for code in [-1, 256, Int.max, Int.min] {
            XCTAssertNil(f.glyphNameOf(code), "\(code)")
            XCTAssertNil(f.programWidth(code), "\(code)")
        }
        let c = try font(try composite(), 5)
        XCTAssertNil(c.glyphNameOf(65))
        XCTAssertNil(c.programWidth(65))
        XCTAssertNil(f.programCidWidth(65))
    }

    func test_programCidWidthReadsTheAdvanceOfACompositeFont() throws {
        let f = try font(try composite(), 5)
        XCTAssertGreaterThan(try XCTUnwrap(f.programCidWidth(try gidOfA())), 0)
        for cid in [-1, Int.max, Int.min] { XCTAssertNil(f.programCidWidth(cid), "\(cid)") }
    }

    func test_aCidToGidMapStreamIsReadAndAnyOtherCidIsGlyphZero() throws {
        let f = try font(try composite("", [0, 0, 0, 5, 0, 7]), 5)
        XCTAssertEqual(f.glyphOf(1), 5)
        XCTAssertEqual(f.glyphOf(2), 7)
        for cid in [3, -1, Int.max, Int.min] { XCTAssertEqual(f.glyphOf(cid), 0, "\(cid)") }
    }

    private func tj(_ text: String, hex: Bool = false, at range: (Int, Int) = (10, 20)) -> ShowPatch {
        ShowPatch(ContentOperation("Tj", [PdfString(bytes: Latin1.bytes(text), isHex: hex)], range.0, range.1))
    }

    private func compiled(_ patch: ShowPatch) -> String { Latin1.string(patch.compile().bytes) }

    func test_showPatchCutsBytesOfOneString() {
        let patch = tj("Hello")
        patch.cut(0, 1, 3)
        let splice = patch.compile()
        XCTAssertEqual(splice.start, 10)
        XCTAssertEqual(splice.end, 20)
        XCTAssertEqual(Latin1.string(splice.bytes), "(Hlo) Tj")
    }

    func test_showPatchInsertsAShiftAndWritesAnArray() {
        let patch = tj("Hello")
        patch.insert(0, 2, [ShowShift(-250)])
        XCTAssertEqual(compiled(patch), "[(He) -250 (llo)] TJ")
    }

    func test_showPatchKeepsHexAndEscapesBytesThatAreNotPrintable() {
        let hex = tj("AB", hex: true)
        hex.cut(0, 1, 2)
        XCTAssertEqual(compiled(hex), "<41> Tj")
        let plain = tj("a\u{1}b")
        plain.cut(0, 0, 1)
        XCTAssertEqual(compiled(plain), "<0162> Tj")
    }

    func test_showPatchCutsOfAnyRangeNeverTrap() {
        let patch = tj("abc")
        patch.cut(0, Int.min, Int.max)
        patch.insert(0, Int.max, [ShowShift(1)])
        patch.insert(0, -1, [ShowShift(1)])
        XCTAssertEqual(compiled(patch), "")
    }

    func test_showPatchTruncateDropsTheLastCutsAndInserts() {
        let patch = tj("abc")
        let before = patch.count
        patch.cut(0, 0, 3)
        patch.insert(0, 1, [ShowShift(5)])
        patch.truncate(before)
        XCTAssertEqual(compiled(patch), "(abc) Tj")
        patch.truncate((cuts: 5, inserts: 5))
        XCTAssertEqual(compiled(patch), "(abc) Tj")
    }

    func test_showPatchQuoteOperatorsStartANewLine() {
        let quote = ShowPatch(ContentOperation("'", [PdfString(bytes: Latin1.bytes("abc"), isHex: false)], 0, 5))
        quote.cut(0, 0, 1)
        XCTAssertEqual(compiled(quote), "T*\n(bc) Tj")
    }

    func test_showPatchDoubleQuoteKeepsItsSpacingAndCutsElementOne() {
        let operands: [PdfObject] = [PdfNumber(1), PdfNumber(2), PdfString(bytes: Latin1.bytes("abc"), isHex: false)]
        let wrong = ShowPatch(ContentOperation("\"", operands, 0, 9))
        wrong.cut(0, 0, 1)
        XCTAssertEqual(compiled(wrong), "1 Tw\n2 Tc\nT*\n(abc) Tj")
        let right = ShowPatch(ContentOperation("\"", operands, 0, 9))
        right.cut(1, 0, 1)
        XCTAssertEqual(compiled(right), "1 Tw\n2 Tc\nT*\n(bc) Tj")
    }

    func test_showPatchWithoutOperandsWritesNothing() {
        XCTAssertEqual(compiled(ShowPatch(ContentOperation("Tj", [], 0, 2))), "")
        XCTAssertEqual(compiled(ShowPatch(ContentOperation("TJ", [], 0, 2))), "")
        XCTAssertEqual(compiled(ShowPatch(ContentOperation("\"", [], 0, 2))), "T*")
    }

    func test_showPatchTJKeepsItsNumbersAndSplitsElements() {
        let array = PdfArray([PdfString(bytes: Latin1.bytes("ab"), isHex: false), PdfNumber(-120), PdfString(bytes: Latin1.bytes("cd"), isHex: false)])
        let patch = ShowPatch(ContentOperation("TJ", [array], 0, 9))
        patch.cut(2, 0, 1)
        XCTAssertEqual(compiled(patch), "[(ab) -120 (d)] TJ")
    }

    private func annotated(_ annots: String, _ more: (TestPdf) -> Void) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [\(annots)]>>")
        pdf.stream(4, "", "")
        more(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    func test_pageAppearancesPlaceTheFormOnTheRect() throws {
        let d = try annotated("5 0 R 7 0 R 8 0 R") { pdf in
            pdf.obj(5, "<</Type /Annot /Subtype /Square /Rect [100 200 300 400] /AP <</N 6 0 R>>>>")
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "")
            pdf.obj(7, "<</Type /Annot /Subtype /Square /F 2 /Rect [0 0 10 10] /AP <</N 6 0 R>>>>")
            pdf.obj(8, "<</Type /Annot /Subtype /Popup /Rect [0 0 10 10] /AP <</N 6 0 R>>>>")
        }
        let page = d.pages[0]
        let all = PageAppearances.of(d, page)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].matrix, PdfMatrix(4, 0, 0, 4, 100, 200))
        XCTAssertEqual(PageAppearances.of(d, page, shownOnly: true).count, 1)
    }

    func test_pageAppearancesSkipAFlatFormAndAnAppearanceStateThatIsMissing() throws {
        let d = try annotated("5 0 R 7 0 R 8 0 R") { pdf in
            pdf.obj(5, "<</Type /Annot /Rect [0 0 10 10] /AP <</N 6 0 R>>>>")
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 0 50]", "")
            pdf.obj(7, "<</Type /Annot /Rect [0 0 10 10] /AS /On /AP <</N <</Off 6 0 R>>>>>>")
            pdf.obj(8, "<</Type /Annot /AP <</N 6 0 R>>>>")
        }
        XCTAssertTrue(PageAppearances.of(d, d.pages[0]).isEmpty)
    }

    func test_parsedStringsDoNotKeepTheCapacityOfTheLongestOne() throws {
        let long = String(repeating: "a", count: 100_000)
        let content = "(\(long)) Tj\n" + String(repeating: "(ab) Tj <4142> Tj\n", count: 50)
        let operations = ContentTestPdf.parse(content)
        XCTAssertEqual(operations.count, 101)
        for operation in operations.dropFirst() {
            let string = try XCTUnwrap(operation.operands.first as? PdfString)
            XCTAssertLessThan(string.bytes.capacity, 1000)
        }
    }

    func test_everyFontOfAPageIsKeptForTheRun() throws {
        let count = 1100
        let entries = (0..<count).map { "/F\($0) \(5 + $0) 0 R" }.joined(separator: " ")
        let content = (0..<count).map { "/F\($0) 12 Tf" }.joined(separator: " ")
        let d = try ContentTestPdf.page(content, "/Font <<\(entries)>>", [String](repeating: ContentTestPdf.helvetica, count: count))
        let interpreter = ContentInterpreter(d)
        interpreter.run(d.pages[0], Recorder())
        XCTAssertEqual(interpreter.fonts.count, count)
    }

    func test_pixelDataThatDoesNotFitTheSizeThrows() throws {
        let d = try PdfDocument.open(TestPdf.simple(1))
        XCTAssertThrowsError(try ContentImages.addRgba(d, 2, 2, [1, 2, 3]))
        XCTAssertThrowsError(try ContentImages.addRgba(d, 0, 1, []))
        XCTAssertThrowsError(try ContentImages.addRgba(d, 12000, 12000, [1, 2, 3, 4]))
        XCTAssertThrowsError(try ContentImages.addRgba(d, Int.max, 2, []))
        XCTAssertThrowsError(try ContentImages.addRgba(d, 2, Int.max, []))
    }
}
