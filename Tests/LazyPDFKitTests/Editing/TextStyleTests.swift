import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/TextStyleTests.cs: the same cases, except that the PdfPig assertion of
// AFamilyWithTurkishLettersIsEmbedded has no twin.

final class TextStyleTests: XCTestCase {
    private let line = "BT /F1 12 Tf 50 700 Td (one two three) Tj ET"

    private final class Probe: ContentVisitor {
        var found: [(text: String, font: String, size: Double)] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            found.append((glyph.unicode ?? "", glyph.font.name, context.state.fontSize))
        }
    }

    private final class ColorProbe: ContentVisitor {
        var colors: [RgbColor] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) { colors.append(context.state.fillColor.rgb) }
    }

    private func fonts(_ session: PdfEditSession) throws -> [(text: String, font: String, size: Double)] {
        let document = try PdfDocument.open(session.current)
        let probe = Probe()
        ContentInterpreter(document).run(document.pages[0], probe)
        return probe.found
    }

    private func distinct(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names where !seen.contains(name) { seen.append(name) }
        return seen
    }

    func test_boldTakesTheBoldFaceOfTheSameFamilyForTheSelectionOnly() throws {
        let session = try EditKit.session(line)
        let result = try PageEditor(session, 0, EditArialSource()).setTextStyle([try EditKit.find(session, "two")], TextStyleChange(bold: true))
        XCTAssertTrue(result.done, result.problem ?? "")
        let found = try fonts(session)
        XCTAssertEqual(found.map { $0.text }.joined(), "one two three")
        XCTAssertEqual(distinct(found.dropFirst(4).prefix(3).map { $0.font }), ["Helvetica-Bold"])
        XCTAssertEqual(distinct((Array(found.prefix(4)) + Array(found.dropFirst(7))).map { $0.font }), ["Helvetica"])
    }

    func test_italicAndAFamilyChangeWork() throws {
        let session = try EditKit.session(line)
        let editor = PageEditor(session, 0, EditArialSource())
        XCTAssertTrue(try editor.setTextStyle([try EditKit.find(session, "one")], TextStyleChange(italic: true)).done)
        XCTAssertTrue(try PageEditor(session, 0, EditArialSource()).setTextStyle([try EditKit.find(session, "three")], TextStyleChange(family: "Times New Roman")).done)
        let found = try fonts(session)
        XCTAssertEqual(found[0].font, "Helvetica-Oblique")
        XCTAssertEqual(found[found.count - 1].font, "Times-Roman")
        XCTAssertEqual(found[4].font, "Helvetica")
        XCTAssertEqual(found.map { $0.text }.joined(), "one two three")
    }

    func test_aFamilyWithTurkishLettersIsEmbedded() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (kagit ve canta) Tj ET")
        XCTAssertTrue(try PageEditor(session, 0, EditArialSource()).replaceText(try EditKit.find(session, "kagit"), "kağıt").done)
        let result = try PageEditor(session, 0, EditArialSource()).setTextStyle([try EditKit.find(session, "kağıt")], TextStyleChange(family: "Verdana", bold: true))
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(try EditKit.text(session).contains("kağıt ve"))
    }

    func test_sizeChangesTheSelectionAndOneUndoStepBringsItBack() throws {
        let session = try EditKit.session(line)
        XCTAssertTrue(try PageEditor(session, 0).setTextStyle([try EditKit.find(session, "two")], TextStyleChange(size: 24)).done)
        let found = try fonts(session)
        XCTAssertEqual([found[0].size, found[5].size, found[10].size], [12, 24, 12])
        XCTAssertEqual(session.undoLabel, "Format text")
        _ = try session.undo()
        for f in try fonts(session) { XCTAssertEqual(f.size, 12) }
    }

    func test_aSelectionOverTwoLinesIsStyledOnBoth() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (first line) Tj 0 -14 Td (second line) Tj ET")
        let editor = PageEditor(session, 0)
        let range = TextRange(0, editor.text.chars.count)
        XCTAssertTrue(try editor.setTextStyle([range], TextStyleChange(color: RgbColor(0, 0, 255))).done)
        let document = try PdfDocument.open(session.current)
        let probe = ColorProbe()
        ContentInterpreter(document).run(document.pages[0], probe)
        for c in probe.colors { XCTAssertEqual(c, RgbColor(0, 0, 255)) }
    }
}
