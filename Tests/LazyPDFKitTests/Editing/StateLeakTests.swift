import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/StateLeakTests.cs: the same cases. Edits put operators round text and
// objects; none of them may change what the content around them draws.

final class StateLeakTests: XCTestCase {
    private struct Shown {
        let text: String
        let x: Double
        let y: Double
        let color: RgbColor
        let tc: Double
        let tw: Double
        let mode: Int
        let size: Double
        let stroke: RgbColor
        let alpha: Double
    }

    private final class Probe: ContentVisitor {
        var found: [Shown] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            let s = context.state
            found.append(Shown(text: glyph.unicode ?? "", x: editRound(glyph.matrix.e, 2), y: editRound(glyph.matrix.f, 2), color: s.fillColor.rgb,
                               tc: s.charSpacing, tw: s.wordSpacing, mode: s.renderMode, size: editRound(glyph.matrix.d, 2),
                               stroke: s.strokeColor.rgb, alpha: s.fillAlpha))
        }
    }

    private func read(_ session: PdfEditSession) throws -> [Shown] {
        let document = try PdfDocument.open(session.current)
        let probe = Probe()
        ContentInterpreter(document).run(document.pages[0], probe)
        return probe.found
    }

    private func of(_ shown: [Shown], _ word: String) -> [Shown] {
        let all = shown.map { $0.text }.joined()
        guard let found = all.range(of: word, options: .literal) else {
            XCTFail(word)
            return []
        }
        let at = found.lowerBound.utf16Offset(in: all)
        return Array(shown[at..<min(at + word.utf16.count, shown.count)])
    }

    private let red = RgbColor(255, 0, 0)
    private let black = RgbColor(0, 0, 0)

    func test_restyleOfLinesDrawnOutOfReadingOrderLeavesTheRestAlone() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 680 Td (line two) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 100 Td (tail) Tj ET")
        let editor = try PageEditor(session, 0)
        let one = try EditKit.find(session, "line one")
        let two = try EditKit.find(session, "line two")
        let result = try editor.setTextStyle([TextRange(one.start, two.end)], TextStyleChange(color: red))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try read(session)
        for g in of(shown, "line one") { XCTAssertEqual(g.color, red) }
        for g in of(shown, "line two") { XCTAssertEqual(g.color, red) }
        for g in of(shown, "tail") { XCTAssertEqual(g.color, black) }
    }

    func test_restyleOfOneColumnLeavesTheOtherColumnAlone() throws {
        let content = "BT /F1 12 Tf 50 700 Td (left top) Tj 300 0 Td (right top) Tj -300 -20 Td (left low) Tj 300 0 Td (right low) Tj ET"
        let session = try EditKit.session(content)
        let editor = try PageEditor(session, 0)
        let a = try EditKit.find(session, "left top")
        let b = try EditKit.find(session, "left low")
        let result = try editor.setTextStyle([TextRange(min(a.start, b.start), max(a.end, b.end))], TextStyleChange(color: red))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try read(session)
        for g in of(shown, "left top") { XCTAssertEqual(g.color, red) }
        for g in of(shown, "left low") { XCTAssertEqual(g.color, red) }
        for g in of(shown, "right top") { XCTAssertEqual(g.color, black) }
        for g in of(shown, "right low") { XCTAssertEqual(g.color, black) }
    }

    func test_textInAFormKeepsTheStateItInheritsWhenItIsRestyled() throws {
        let session = try EditKit.session("1 0 0 rg 0.5 Tc /Fm0 Do",
            more: { pdf in pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET") },
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>>")
        let editor = try PageEditor(session, 0)
        let hello = try EditKit.find(session, "Hello")
        XCTAssertTrue(try editor.setTextStyle([hello], TextStyleChange(charSpacing: 0.25)).done)
        let shown = try read(session)
        for g in of(shown, "Hello") { XCTAssertEqual(g.tc, 0.25) }
        for g in of(shown, "World") {
            XCTAssertEqual(g.tc, 0.5)
            XCTAssertEqual(g.color, red)
        }
        editor.refresh()
        XCTAssertTrue(try editor.setTextStyle([try EditKit.find(session, "Hello")], TextStyleChange(color: RgbColor(0, 0, 255))).done)
        for g in of(try read(session), "World") { XCTAssertEqual(g.color, red) }
    }

    func test_addedTextIsNotHiddenByRenderModeTheTopLevelLeft() throws {
        let session = try EditKit.session("BT /F1 12 Tf 3 Tr 50 700 Td (ocr layer) Tj ET")
        let result = try PageEditor(session, 0, EditArialSource()).addTextBox(PdfRect(100, 300, 300, 400), "visible")
        XCTAssertTrue(result.done, result.problem ?? "")
        for g in of(try read(session), "visible") { XCTAssertEqual(g.mode, 0) }
    }

    func test_addedTextAndShapesStartFromTheDefaultState() throws {
        let session = try EditKit.session("BT /F1 12 Tf 2 Tc 3 Tw 50 700 Td (ocr layer) Tj ET 0 0 1 rg 0 0 600 800 re W n 1 0 0 1 10 10 cm")
        let editor = try PageEditor(session, 0, EditArialSource())
        XCTAssertTrue(try editor.addTextBox(PdfRect(100, 300, 300, 400), "visible").done)
        let added = of(try read(session), "visible")
        for g in added {
            XCTAssertEqual(g.tc, 0)
            XCTAssertEqual(g.tw, 0)
            XCTAssertEqual(g.color, black)
        }
        XCTAssertEqual(added[0].x, 100, accuracy: 0.5)
    }

    func test_quoteOperatorSpacingSurvivesARestyleOfTheTextBefore() throws {
        let session = try EditKit.session("BT /F1 12 Tf 14 TL 50 700 Td 2 1 (abc) \" (def) Tj ( ghi) Tj ET")
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.setTextStyle([try EditKit.find(session, "def")], TextStyleChange(charSpacing: 4)).done)
        let shown = try read(session)
        for g in of(shown, "ghi") { XCTAssertEqual(g.tc, 1) }
        for g in of(shown, "def") { XCTAssertEqual(g.tc, 4) }
    }

    func test_operatorsInsertedAtAnOperationStartAreSeparatedFromTheOperatorBefore() throws {
        let session = try EditKit.session("q 100 0 0 100 0 0 cm/Im0 Do Q",
            more: { pdf in pdf.stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0]) },
            resources: "/XObject <</Im0 7 0 R>>")
        let editor = try PageEditor(session, 0)
        let before = try EditPaint.images(session)
        XCTAssertTrue(try editor.move(try editor.objects.filter { $0 is ImageObject }, 30, 40).done)
        let after = try EditPaint.images(session)
        XCTAssertEqual(after[0].matrix.e, before[0].matrix.e + 30, accuracy: 0.0005)
        XCTAssertEqual(after[0].matrix.f, before[0].matrix.f + 40, accuracy: 0.0005)
        XCTAssertEqual(after[0].matrix.a, 100, accuracy: 0.0005)
    }

    func test_objectsAreNotMovedPastAMatrixClipOrMarkedContent() throws {
        for between in ["1 0 0 1 100 100 cm", "0 0 20 20 re W n", "0 1 0 rg", "/GS0 gs", "EMC"] {
            let content = (between == "EMC" ? "/OC /MC0 BDC " : "") + "q 1 0 0 rg 0 0 50 50 re f Q " + between + " q 0 0 1 rg 0 0 50 50 re f Q"
            let session = try EditKit.session(content, more: { pdf in pdf.obj(7, "<</Type /ExtGState /ca 0.5>>") }, resources: "/Font <</F1 5 0 R>> /ExtGState <</GS0 7 0 R>>")
            let editor = try PageEditor(session, 0)
            let paths = try editor.objects.compactMap { $0 as? PathObject }
            XCTAssertEqual(paths.count, 2, between)
            let result = try editor.order(paths[1], .backward)
            XCTAssertFalse(result.done, between)
            XCTAssertEqual(EditKit.latin(session), content, between)
        }
    }

    func test_objectsAreStillMovedPastWhollyEnclosedSiblings() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q q 1 0 0 1 100 100 cm 0 1 0 rg 0 0 50 50 re f Q q 0 0 1 rg 0 0 50 50 re f Q")
        let editor = try PageEditor(session, 0)
        let paths = try editor.objects.compactMap { $0 as? PathObject }
        XCTAssertTrue(try editor.order(paths[2], .backward).done)
        XCTAssertEqual(try EditPaint.paths(session)[1].fill, RgbColor(0, 0, 255))
    }

    func test_spacingSetByTheQuoteOperatorAloneDoesNotReachAddedText() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td 5 2 (Hello) \" ET")
        let editor = try PageEditor(session, 0, EditArialSource())
        XCTAssertTrue(try editor.addTextBox(PdfRect(100, 300, 300, 400), "new text").done)
        for g in of(try read(session), "new") {
            XCTAssertEqual(g.tc, 0)
            XCTAssertEqual(g.tw, 0)
        }
    }

    func test_textRestyledAcrossARenderModeChangeKeepsItsStrokeInTheNewColour() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (abc) Tj 1 Tr (def) Tj ET")
        let editor = try PageEditor(session, 0)
        let result = try editor.setTextStyle([try EditKit.find(session, "abcdef")], TextStyleChange(color: red))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try read(session)
        for g in of(shown, "abc") { XCTAssertEqual(g.color, red) }
        for g in of(shown, "def") {
            XCTAssertEqual(g.color, red)
            XCTAssertEqual(g.stroke, red)
        }
    }

    func test_addedContentAfterAStrayRestoreDoesNotInheritWhatThePageLeftSet() throws {
        let session = try EditKit.session("Q /GS0 gs BT 3 Tr 5 Tc 2 Tw /F1 12 Tf 50 700 Td (ocr) Tj ET",
            resources: "/Font <</F1 5 0 R>> /ExtGState <</GS0 <</ca 0.5>>>>")
        let editor = try PageEditor(session, 0, EditArialSource())
        XCTAssertTrue(try editor.addTextBox(PdfRect(100, 300, 300, 400), "new").done)
        for g in of(try read(session), "new") {
            XCTAssertEqual(g.mode, 0)
            XCTAssertEqual(g.tc, 0)
            XCTAssertEqual(g.tw, 0)
            XCTAssertEqual(g.alpha, 1)
        }
    }
}
