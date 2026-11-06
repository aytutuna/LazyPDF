import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/TwinAndReplaceTests.cs: the same cases. Text drawn twice at one place,
// regex replacement and edits taken back. The regular expressions run in ICU here (PORTING.md, Known differences).

final class TwinAndReplaceTests: XCTestCase {
    private final class Probe: ContentVisitor {
        var found: [(text: String, mode: Int, x: Double)] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            found.append((glyph.unicode ?? "", context.state.renderMode, editRound(glyph.matrix.e, 2)))
        }
    }

    private func read(_ session: PdfEditSession) throws -> [(text: String, mode: Int, x: Double)] {
        let document = try PdfDocument.open(session.current)
        let probe = Probe()
        ContentInterpreter(document).run(document.pages[0], probe)
        return probe.found
    }

    private func page(_ session: PdfEditSession) throws -> String { DotNetText.trim(try EditKit.text(session)) }

    // The resource names LzE<n> followed by a space in a content stream.
    private func standInNames(_ content: String) -> [String] {
        var names: [String] = []
        var rest = Substring(content)
        while let at = rest.range(of: "/LzE") {
            let digits = rest[at.upperBound...].prefix { $0.isASCII && $0.isNumber }
            let end = at.upperBound
            if !digits.isEmpty, rest[end...].dropFirst(digits.count).first == " " { names.append("LzE" + digits) }
            rest = rest[at.upperBound...]
        }
        return names
    }

    func test_aTwinInAnotherFontGetsTheCodesOfItsOwnFont() throws {
        let swapped = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /B 66 /A]>>>>"
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (AB) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (BA) Tj ET",
                                          more: { pdf in pdf.obj(7, swapped) }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>")
        let editor = PageEditor(session, 0)
        let result = try editor.replaceText(try EditKit.find(session, "AB"), "BA")
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try read(session)
        XCTAssertEqual(shown.filter { $0.mode == 0 }.map { $0.text }.joined(), "BA")
        XCTAssertEqual(shown.filter { $0.mode == 3 }.map { $0.text }.joined(), "BA")
    }

    func test_aTwinInAnotherFormKeepsItsOwnStandInFont() throws {
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>"
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (ab) Tj ET /Fm0 Do",
                                          more: { pdf in pdf.stream(7, form, "BT /F1 12 Tf 3 Tr 50 700 Td (ab) Tj ET") },
                                          resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>>")
        let editor = PageEditor(session, 0, EditArialSource())
        let result = try editor.replaceText(try EditKit.find(session, "ab"), "ğş")
        XCTAssertTrue(result.done, result.problem ?? "")
        let document = try PdfDocument.open(session.current)
        let form0 = try XCTUnwrap(document.resolve(document.dict(document.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        let fonts = try XCTUnwrap(document.dict(document.dict(form0.dictionary, "Resources"), "Font"))
        let content = Latin1.string(try document.data(form0))
        for name in standInNames(content) { XCTAssertNotNil(fonts[name]) }
        XCTAssertTrue(content.contains("/LzE"))
    }

    func test_aLookbehindIsSeenInTheTextOfThePage() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Total 42 and 17) Tj ET")
        let report = try TextReplacer.replaceAll(session, "(?<=Total )\\d+", "99", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "Total 99 and 17")
    }

    func test_aGroupOfAFoldedMatchKeepsTheAccentsOfThePage() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (A café here) Tj ET")
        let report = try TextReplacer.replaceAll(session, "(cafe) here", "<$1>", TextSearchOptions(regex: true, foldDiacritics: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "A <café>")
    }

    func test_everyWordOfAFoldedSearchKeepsItsAccents() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (A café here) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(\\w+)", "<$1>", TextSearchOptions(regex: true, foldDiacritics: true))
        XCTAssertEqual(try page(session), "<A> <café> <here>")
    }

    func test_aMatchThatExistsOnlyOnTheFoldedTextIsExpandedWithItsGroup() throws {
        let dotted = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [73 /Idotaccent]>>>>"
        let session = try EditKit.session("BT /F3 12 Tf 50 700 Td (ZMIR) Tj ET", more: { pdf in pdf.obj(7, dotted) }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>")
        XCTAssertEqual(try page(session), "ZMİR")
        let report = try TextReplacer.replaceAll(session, "(zmi)r", "<$1>", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "<ZMİ>")
    }

    func test_aDollarInAGroupOfThePageIsWrittenAsItIs() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (cost $5 now) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(\\$\\d)", "[$1]$$", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "cost [$5]$ now")
    }

    func test_aStandInOfATakenBackMatchIsNotReported() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (a) Tj /F1 20 Tf (b) Tj ET")
        let document = session.document
        let model = PageModel.load(document, 0)
        let batch = EditBatch(document, model.page, model.scan)
        let fonts = EditArialSource()
        let builder = TextBuilder(document, batch, fonts)
        let editor = TextEditor(model, batch, builder, fonts)
        let mark = batch.save()
        XCTAssertThrowsError(try editor.replace(try EditKit.find(session, "ab"), "ğ中")) { XCTAssertTrue($0 is EditConflictException) }
        batch.restore(mark)
        XCTAssertTrue(builder.substitutions.isEmpty)
    }

    func test_aRegexGroupKeepsTheCaseOfThePage() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(w\\w+)", "[$1]", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "Hello [World]")
    }

    func test_aStandInOfATakenBackEditIsNotUsedByTheNextOne() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (a) Tj /F1 20 Tf (b) Tj ET BT /F1 12 Tf 50 600 Td (c) Tj ET")
        let document = session.document
        let model = PageModel.load(document, 0)
        let batch = EditBatch(document, model.page, model.scan)
        let fonts = EditArialSource()
        let builder = TextBuilder(document, batch, fonts)
        let editor = TextEditor(model, batch, builder, fonts)
        let objects = document.objectNumbers.count

        let mark = batch.save()
        XCTAssertThrowsError(try editor.replace(try EditKit.find(session, "ab"), "ğ中")) { XCTAssertTrue($0 is EditConflictException) }
        batch.restore(mark)
        XCTAssertEqual(document.objectNumbers.count, objects)

        try editor.replace(try EditKit.find(session, "c"), "ğ")
        try batch.apply()
        builder.writeAdditions()
        try session.commit("test")
        let reopened = try PdfDocument.open(session.current)
        let content = Latin1.string(reopened.pages[0].contents())
        let names = standInNames(content)
        XCTAssertFalse(names.isEmpty)
        let font = try XCTUnwrap(reopened.dict(reopened.pages[0].resources, "Font"))
        for n in names { XCTAssertNotNil(font[n]) }
    }

    func test_aFailedEditLeavesNoObjectsBehind() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (abc) Tj ET")
        let before = session.document.objectNumbers.count
        let result = try PageEditor(session, 0, EditArialSource()).addTextBox(PdfRect(100, 300, 300, 400), "中文")
        XCTAssertFalse(result.done)
        XCTAssertEqual(session.document.objectNumbers.count, before)
    }

    private let twoPlace = "BT /F1 12 Tf 14 TL 50 700 Td (Hello) Tj 40 0 Td (World) Tj -40 -14 Td (a much longer second line here) Tj ET"

    func test_rightAlignMovesEveryPositionedRunOfALine() throws {
        let session = try EditKit.session(twoPlace)
        let editor = PageEditor(session, 0)
        let before = try read(session)
        XCTAssertTrue(try editor.setAlignment(try assertSingle(editor.objects.compactMap { $0 as? TextObject }), .right).done)
        let after = try read(session)
        XCTAssertEqual(before.count, after.count)
        let shift = after[0].x - before[0].x
        XCTAssertTrue(shift > 20)
        for i in 0..<10 { XCTAssertEqual(after[i].x, before[i].x + shift, accuracy: 0.05) }
    }

    func test_alignMovesADoubleStruckLineTogether() throws {
        let content = "BT /F1 12 Tf 14 TL 50 700 Td (Hello) Tj ET BT /F1 12 Tf 50.2 700 Td (Hello) Tj ET BT /F1 12 Tf 50 686 Td (a much longer second line here) Tj ET"
        let session = try EditKit.session(content)
        let editor = PageEditor(session, 0)
        let block = try assertSingle(editor.objects.compactMap { $0 as? TextObject })
        let before = try read(session)
        XCTAssertTrue(try editor.setAlignment(block, .right).done)
        let after = try read(session)
        XCTAssertEqual(after[0].x - before[0].x, after[5].x - before[5].x, accuracy: 0.005)
        XCTAssertTrue(after[0].x - before[0].x > 20)
    }

    func test_theTailOfAHiddenCopyThatCannotShowTheNewLettersStaysWhereItWas() throws {
        let cut = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 68 /Widths [\(Array(repeating: "600", count: 37).joined(separator: " "))] /Encoding /WinAnsiEncoding>>"
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (AB CD) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB CD) Tj ET",
                                          more: { pdf in pdf.obj(7, cut) }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>")
        let tail = try read(session).filter { $0.mode == 3 && ($0.text == "C" || $0.text == "D") }
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "AB"), "XY")
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try read(session).filter { $0.mode == 3 && ($0.text == "C" || $0.text == "D") }
        XCTAssertEqual(tail.map { $0.text }, after.map { $0.text })
        XCTAssertEqual(tail.map { $0.x }, after.map { $0.x })
    }

    func test_theWholeMatchOfARegexIsTheCaseOfThePage() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET")
        let report = try TextReplacer.replaceAll(session, "H\\w+", "[$&]", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "[Hello] World")
    }

    func test_theTextAroundAMatchAndTheLastGroupComeFromThePage() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Ab Cd!) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(c)d", "<$`|$'|$+>", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "Ab <Ab |!|C>!")
    }

    func test_aDollarEscapeIsNotTakenForTheStartOfAGroup() throws {
        var session = try EditKit.session("BT /F1 12 Tf 50 700 Td (cost 42 now) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(\\d+)", "$$1", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "cost $1 now")
        session = try EditKit.session("BT /F1 12 Tf 50 700 Td (cost 42 now) Tj ET")
        _ = try TextReplacer.replaceAll(session, "\\d+", "$$0.99", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "cost $0.99 now")
    }

    func test_theSpacesAtTheEdgesOfAGroupAreKept() throws {
        var session = try EditKit.session("BT /F1 12 Tf 50 700 Td (cost 42 USD now) Tj ET")
        let report = try TextReplacer.replaceAll(session, "(\\d+)( USD)", "$1$2!", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "cost 42 USD! now")
        session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET")
        _ = try TextReplacer.replaceAll(session, "(\\w+)( )(\\w+)", "$3$2$1", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "World Hello")
    }

    func test_theWholeInputOfARegexIsThePageToo() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET")
        _ = try TextReplacer.replaceAll(session, "H\\w+", "[$_]", TextSearchOptions(regex: true))
        XCTAssertEqual(try page(session), "[Hello World] World")
    }

    func test_aGroupWrittenWithALeadingZeroIsTheGroupOfThePageEvenWithNamedGroups() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (HELLO) Tj ET")
        let report = try TextReplacer.replaceAll(session, "(?<y>h)(\\w+)", "$01", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session), "ELLO")
    }

    func test_theTailOfAHiddenCopyFollowsTheNewTextWhenItIsWiderThanTheOldOne() throws {
        let cut = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 68 /Widths [278 \(Array(repeating: "600", count: 32).joined(separator: " ")) 667 667 722 722] /Encoding /WinAnsiEncoding>>"
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (AB CD) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB CD) Tj ET",
                                          more: { pdf in pdf.obj(7, cut) }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>")
        func gap(_ shown: [(text: String, mode: Int, x: Double)], _ letter: String) throws -> Double {
            let hidden = try assertSingle(shown.filter { $0.mode == 3 && $0.text == letter })
            let visible = try assertSingle(shown.filter { $0.mode == 0 && $0.text == letter })
            return hidden.x - visible.x
        }
        XCTAssertEqual(try gap(try read(session), "C"), 0, accuracy: 0.005)
        let text = try page(session)
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "AB"), "WWWW")
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try read(session)
        XCTAssertEqual(try gap(after, "C"), 0, accuracy: 0.005)
        XCTAssertEqual(try gap(after, "D"), 0, accuracy: 0.005)
        XCTAssertEqual(try page(session), text.replacingOccurrences(of: "AB", with: "WWWW"))
    }
}
