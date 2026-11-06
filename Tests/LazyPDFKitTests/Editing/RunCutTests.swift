import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/RunCutTests.cs: the same cases. Operators put round a run of glyphs must
// reach those glyphs and nothing the stream sets again or closes in between.

final class RunCutTests: XCTestCase {
    private let red = RgbColor(255, 0, 0)

    private func across(_ session: PdfEditSession, _ from: String, _ to: String) throws -> TextRange {
        TextRange(try EditKit.find(session, from).start, try EditKit.find(session, to).end)
    }

    func test_restyleReachesTextObjectsThatSetTheirOwnColourAndFont() throws {
        let content = "BT /F1 12 Tf 0 0 0 rg 50 700 Td (line one) Tj ET BT /F1 12 Tf 0 0 0 rg 50 680 Td (line two) Tj ET"
        let session = try EditKit.session(content)
        let one = try EditKit.find(session, "line one")
        let two = try EditKit.find(session, "line two")
        let result = try PageEditor(session, 0).setTextStyle([TextRange(one.start, two.end)], TextStyleChange(size: 20, color: red))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        for g in EditKit.of(shown, "line one") {
            XCTAssertEqual(g.color, red)
            XCTAssertEqual(g.size, 20)
        }
        for g in EditKit.of(shown, "line two") {
            XCTAssertEqual(g.color, red)
            XCTAssertEqual(g.size, 20)
        }
    }

    func test_restyleReachesTextAfterACharacterSpacingChangeInsideTheRange() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (abc) Tj 0.5 Tc (def) Tj ET BT 50 600 Td (tail) Tj ET")
        let result = try PageEditor(session, 0).setTextStyle([try across(session, "abc", "def")], TextStyleChange(charSpacing: 2))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        for g in EditKit.of(shown, "abc") { XCTAssertEqual(g.tc, 2) }
        for g in EditKit.of(shown, "def") { XCTAssertEqual(g.tc, 2) }
        for g in EditKit.of(shown, "tail") { XCTAssertEqual(g.tc, 0.5) }
    }

    func test_strikesInTheirOwnQGroupsAreJoinedByAJustifyAndByARestyle() throws {
        let content = "q BT /F1 12 Tf 14 TL 50 700 Td (Hello big) Tj ET Q q BT /F1 12 Tf 50.2 700 Td (Hello big) Tj ET Q q BT /F1 12 Tf 50 686 Td (a much longer second line here) Tj ET Q"
        let session = try EditKit.session(content)
        var editor = PageEditor(session, 0)
        let result = try editor.setAlignment(try assertSingle(editor.objects.compactMap { $0 as? TextObject }), .justify)
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        XCTAssertTrue(shown[5].tw > 0)
        XCTAssertEqual(shown[5].tw, shown[14].tw)

        editor = PageEditor(session, 0)
        let restyle = try editor.setTextStyle([try across(session, "Hello", "big")], TextStyleChange(color: red))
        XCTAssertTrue(restyle.done, restyle.problem ?? "")
        for g in try EditKit.shown(session).prefix(18) where g.text != " " { XCTAssertEqual(g.color, red) }
    }

    func test_spacingOfTheQuoteOperatorIsPutBackAfterNewTextInAnotherStyle() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td 2 1 (abc def) \" ( ghi) Tj ET")
        let editor = PageEditor(session, 0, EditArialSource())
        let result = try editor.setTextStyle([try EditKit.find(session, "abc")], TextStyleChange(bold: true, charSpacing: 4))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        for g in EditKit.of(shown, "abc") { XCTAssertEqual(g.tc, 4) }
        for g in EditKit.of(shown, "def") { XCTAssertEqual(g.tc, 1) }
        for g in EditKit.of(shown, "ghi") { XCTAssertEqual(g.tc, 1) }
    }

    func test_aHiddenCopyThatCannotShowTheNewLettersIsCutAndTheEditGoesThrough() throws {
        let cut = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 66 /Widths [600 600] /Encoding /WinAnsiEncoding>>"
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (AB) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB) Tj ET",
                                          more: { pdf in pdf.obj(7, cut) }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "AB"), "XY")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(DotNetText.trim(try EditKit.text(session)), "XY")
        XCTAssertFalse(EditKit.latin(session).contains("(AB)"))
    }
}
