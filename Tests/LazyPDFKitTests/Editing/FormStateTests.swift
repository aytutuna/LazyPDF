import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/FormStateTests.cs: the same cases. A form starts from the state of the Do
// that paints it, with the names it inherits read in its own resources.

final class FormStateTests: XCTestCase {
    private let red = RgbColor(255, 0, 0), green = RgbColor(0, 255, 0), blue = RgbColor(0, 0, 255)

    private func open(_ page: String, _ form: String, _ formResources: String, _ pageResources: String = "") throws -> PdfEditSession {
        try EditKit.session(page, more: { pdf in
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <<\(formResources)>>", form)
        }, resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>> " + pageResources)
    }

    private func formData(_ session: PdfEditSession) throws -> String {
        let document = try PdfDocument.open(session.current)
        let forms = try XCTUnwrap(document.dict(document.pages[0].resources, "XObject"))
        let stream = try XCTUnwrap(document.resolve(forms["Fm0"]) as? PdfStream)
        return Latin1.string(try document.data(stream, 1 << 20))
    }

    func test_aRestoreInTheSecondPaintingOfAFormUsesTheStateOfThatPainting() throws {
        let session = try open("1 0 0 rg /Fm0 Do 0 0 1 rg 1 0 0 1 0 -100 cm /Fm0 Do", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>")
        let second = try TextSearch.find(TextPage.create(session.document, session.document.pages[0]), "Hello", TextSearchOptions(matchCase: true))[1]
        let result = try PageEditor(session, 0).setTextStyle([second.range], TextStyleChange(color: green))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        for g in shown.prefix(11) where g.text != " " { XCTAssertEqual(g.color, red) }
        let later = Array(shown.dropFirst(11))
        for g in EditKit.of(later, "Hello") { XCTAssertEqual(g.color, green) }
        for g in EditKit.of(later, "World") { XCTAssertEqual(g.color, blue) }
    }

    func test_aFontNamedInTheCallerIsNotInheritedByAFormWithResourcesOfItsOwn() throws {
        let session = try open("BT /F1 12 Tf ET /Fm0 Do", "BT 50 700 Td (Hello World) Tj ET", "/Font <</F9 5 0 R>>")
        let before = try formData(session)
        let result = try PageEditor(session, 0).setTextStyle([try EditKit.find(session, "Hello")], TextStyleChange(size: 20))
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.fontSetOutside)
        XCTAssertEqual(before, try formData(session))
    }

    func test_aColourSpaceNamedInTheCallerCannotBeRestoredInAFormThatLacksIt() throws {
        let spot = "/ColorSpace <</Cs1 [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>]>>"
        let session = try open("/Cs1 cs 1 sc /Fm0 Do", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>", spot)
        let before = try formData(session)
        let result = try PageEditor(session, 0).setTextStyle([try EditKit.find(session, "Hello")], TextStyleChange(color: blue))
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.colorOutside)
        XCTAssertEqual(before, try formData(session))
    }

    func test_aNameThatMeansTheSameInTheFormIsStillInherited() throws {
        let session = try open("BT /F1 12 Tf ET /Fm0 Do", "BT 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>")
        let result = try PageEditor(session, 0).setTextStyle([try EditKit.find(session, "Hello")], TextStyleChange(size: 20))
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        for g in EditKit.of(shown, "Hello") { XCTAssertEqual(g.size, 20) }
        for g in EditKit.of(shown, "World") { XCTAssertEqual(g.size, 12) }
    }

    func test_aParagraphLineInAFontThatCannotBeRestoredInTheFormIsRefused() throws {
        let session = try open("BT /F1 12 Tf ET /Fm0 Do",
            "BT 50 686 Td (second line) Tj 0 -300 Td (far text) Tj ET BT /F9 12 Tf 50 700 Td (first line) Tj ET", "/Font <</F9 6 0 R>>")
        let before = try formData(session)
        let editor = try PageEditor(session, 0)
        let block = try assertSingle(try editor.objects.compactMap { $0 as? TextObject }.filter { $0.lines.count == 2 })
        let result = try editor.replaceParagraph(block, "alpha\nbeta")
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.fontSetOutside)
        XCTAssertEqual(before, try formData(session))
    }

    func test_aTransparencyGroupDoesNotInheritTheGraphicsStateOfTheCaller() throws {
        let session = try EditKit.session("/GS0 gs /Fm0 Do",
            more: { pdf in
                pdf.obj(8, "<</Type /ExtGState /ca 0.5>>")
                pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency>> /Resources <</Font <</F1 5 0 R>> /ExtGState <</GS0 8 0 R>>>>",
                           "BT /F1 12 Tf 50 700 Td (one) Tj ET")
            },
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>> /ExtGState <</GS0 8 0 R>>")
        let editor = try PageEditor(session, 0)
        let result = try editor.replaceParagraph(try assertSingle(try editor.objects.compactMap { $0 as? TextObject }), "one\ntwo")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertFalse(try formData(session).contains("gs"))
    }

    func test_thePaintingOfAFormThatSetsTheModeIsTheOneOrderLooksAt() throws {
        let form = "q 1 0 0 rg 0 0 50 50 re f Q BT /F1 12 Tf (x) Tj ET q 0 0 1 rg 100 0 50 50 re f Q"
        let session = try open("/Fm0 Do 7 Tr /Fm0 Do", form, "/Font <</F1 5 0 R>>")
        let editor = try PageEditor(session, 0)
        let last = try XCTUnwrap(try editor.objects.compactMap { $0 as? PathObject }.last)
        let result = try editor.order(last, .backward)
        XCTAssertFalse(result.done)
        XCTAssertEqual(try assertSingle(result.skipped).reason, EditingText.stateBetween)
    }
}
