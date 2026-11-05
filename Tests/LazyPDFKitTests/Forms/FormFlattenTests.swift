import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormFlattenTests.cs: the same cases. PdfPig has no Swift twin; the page text is
// read with the Text layer from the file written and read again.

final class FormFlattenTests: XCTestCase {
    private func filled(_ acroEntries: String = "") throws -> PdfForm {
        let form = PdfForm.read(try FormFixtures.open(acroEntries))
        try form.setValues([("name", "Ada Lovelace"), ("agree", "Yes"), ("choice", "b"), ("city", "Izmir"), ("code", "123")])
        return form
    }

    private func pageText(_ document: PdfDocument, _ page: Int = 0) throws -> String {
        let written = try PdfDocument.open(try document.saveRewrite())
        return TextPage.create(written, written.pages[page]).text
    }

    func test_flatteningEverythingLeavesTextOnThePageAndNoForm() throws {
        let form = try filled()

        let burned = try form.flatten()

        XCTAssertEqual(burned, 9)
        XCTAssertTrue(form.fields.isEmpty)
        XCTAssertNil(form.acroForm)
        XCTAssertEqual(form.document.array(form.document.pages[0].dictionary, "Annots")?.items.count, 0)
        let text = try pageText(form.document)
        XCTAssertTrue(text.contains("Ada Lovelace"))
        XCTAssertTrue(text.contains("Izmir"))
        let reopened = try AnnotationFixtures.reopen(form.document)
        XCTAssertTrue(PdfForm.read(reopened).fields.isEmpty)
        XCTAssertTrue(PdfAnnotations.readAll(reopened).isEmpty)
    }

    func test_flatteningSomeFieldsKeepsTheRest() throws {
        let form = try filled()

        let burned = try form.flatten([try XCTUnwrap(form.find("name")), try XCTUnwrap(form.find("choice"))])

        XCTAssertEqual(burned, 3)
        XCTAssertNil(form.find("name"))
        XCTAssertNil(form.find("choice"))
        XCTAssertNotNil(form.find("city"))
        XCTAssertNotNil(form.acroForm)
        let listed = try XCTUnwrap(form.document.array(form.acroForm, "Fields")).items.compactMap { item -> String? in
            guard let d = form.document.resolve(item) as? PdfDictionary else { return nil }
            return PdfText.read(form.document, d, "T")
        }
        XCTAssertFalse(listed.contains("name") || listed.contains("choice"))
        XCTAssertTrue(try pageText(form.document).contains("Ada Lovelace"))
        let reopened = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        XCTAssertEqual(reopened.fields.map { $0.name }.sorted(), ["agree", "bio", "city", "code", "langs", "secret", "sig"])
    }

    func test_hiddenWidgetsAreDroppedWithoutALeftoverAnnotation() throws {
        let form = try filled()
        try XCTUnwrap(form.find("name")).widgets[0].dictionary["F"] = PdfNumber(AnnotationFlags.hidden.rawValue)

        try form.flatten()

        XCTAssertFalse(try pageText(form.document).contains("Ada Lovelace"))
        XCTAssertEqual(form.document.array(form.document.pages[0].dictionary, "Annots")?.items.count, 0)
    }

    func test_staleAppearancesAreDrawnAgainWhenTheFormSaysSo() throws {
        let form = PdfForm.read(try FormFixtures.open("/NeedAppearances true"))
        try XCTUnwrap(form.find("name")).dictionary["V"] = PdfText.toObject("typed by another program")
        form.refresh()

        try form.flatten([try XCTUnwrap(form.find("name"))])

        XCTAssertTrue(try pageText(form.document).contains("typed by another program"))
    }

    func test_fieldsWithoutAnAppearanceAreDrawnBeforeTheyAreBurned() throws {
        let form = PdfForm.read(try FormFixtures.open())
        try XCTUnwrap(form.find("bio")).dictionary["V"] = PdfText.toObject("set without drawing")
        form.refresh()

        try form.flatten()

        XCTAssertTrue(try pageText(form.document).contains("set without drawing"))
    }

    func test_flatteningAStaticXfaFormRemovesTheXfa() throws {
        let form = try filled("/XFA [(template) 12 0 R]")

        try form.flatten()

        XCTAssertFalse(form.document.hasXfa)
        XCTAssertTrue(form.xfaRemoved)
    }

    func test_flattenedFormsKeepAnOtherPageUntouched() throws {
        let form = PdfForm.read(try AnnotationFixtures.blank())
        try form.addField(FieldSpec(.text, "p1", 0, PdfRect(50, 700, 250, 720), value: "one"))
        try form.addField(FieldSpec(.text, "p2", 1, PdfRect(50, 700, 250, 720), value: "two"))

        XCTAssertEqual(try form.flatten(), 2)

        XCTAssertTrue(try pageText(form.document, 0).contains("one"))
        XCTAssertTrue(try pageText(form.document, 1).contains("two"))
    }
}
