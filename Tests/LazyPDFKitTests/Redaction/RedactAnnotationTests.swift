import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactAnnotationTests.cs: the same cases.

final class RedactAnnotationTests: XCTestCase {
    private let hole = PdfRect(90, 480, 310, 520)

    private func blank() throws -> PdfDocument { try RedactionKit.page("BT /F1 12 Tf 100 700 Td (page text) Tj ET") }

    @discardableResult
    private func note(_ document: PdfDocument, _ rect: PdfRect, _ contents: String) throws -> PdfAnnotation {
        try PdfAnnotationWriter(document).addNote(document.pages[0], rect, AnnotationInfo(author: "Reviewer", contents: contents))
    }

    private func over() -> RedactionMark { RedactionMark.fromRect(0, hole) }

    func test_noteUnderTheMarkGoesWithItsPopupAndRepliesAndOtherNotesStay() throws {
        let document = try blank()
        let inside = try note(document, PdfRect(100, 490, 120, 510), "secret remark")
        try note(document, PdfRect(400, 100, 420, 120), "elsewhere")
        let popupDictionary = PdfDictionary()
        popupDictionary["Type"] = PdfName("Annot")
        popupDictionary["Subtype"] = PdfName("Popup")
        popupDictionary["Rect"] = PdfRect(500, 600, 600, 700).toArray()
        popupDictionary["Parent"] = try XCTUnwrap(inside.reference)
        let popup = try document.add(popupDictionary)
        inside.dictionary["Popup"] = popup
        try XCTUnwrap(document.array(document.pages[0].dictionary, "Annots")).items.append(popup)

        let result = try PdfRedactor(document).apply([over()])
        let output = try RedactionKit.open(result)
        let left = PdfAnnotations.read(output, output.pages[0])
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.contents, "elsewhere")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "secret remark"))
        XCTAssertEqual(result.report.annotations, 1)
    }

    func test_linkOverTheMarkIsRemoved() throws {
        let document = try blank()
        try PdfAnnotationWriter(document).addLink(document.pages[0], PdfRect(100, 490, 200, 510), UriAction("https://example.com/secret") as PdfAction)
        let result = try PdfRedactor(document).apply([over()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(PdfAnnotations.read(output, output.pages[0]).isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "example.com/secret"))
    }

    func test_fieldWithItsValueGoesAndAnAcroFormWithNoFieldLeftGoesToo() throws {
        let document = try blank()
        let form = PdfForm.read(document)
        try form.addField(FieldSpec(.text, "name", 0, PdfRect(100, 490, 300, 510), value: "Jane Doe secret"))
        XCTAssertNotNil(document.dict(document.catalog, "AcroForm"))
        let result = try PdfRedactor(document).apply([over()])
        let output = try RedactionKit.open(result)
        XCTAssertNil(output.dict(output.catalog, "AcroForm"))
        XCTAssertTrue(PdfAnnotations.read(output, output.pages[0]).isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "Jane Doe secret"))
        XCTAssertEqual(result.report.fields, 1)
    }

    func test_otherFieldsKeepTheFormAlive() throws {
        let document = try blank()
        let form = PdfForm.read(document)
        try form.addField(FieldSpec(.text, "name", 0, PdfRect(100, 490, 300, 510), value: "gone value"))
        try form.addField(FieldSpec(.text, "city", 0, PdfRect(100, 300, 300, 320), value: "kept value"))
        let result = try PdfRedactor(document).apply([over()])
        let output = try RedactionKit.open(result)
        let fields = PdfForm.read(output).fields
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.name, "city")
        XCTAssertEqual(fields.first?.value, "kept value")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "gone value"))
    }

    func test_aRadioGroupWithOneButtonUnderTheMarkLeavesNothing() throws {
        let document = try blank()
        let form = PdfForm.read(document)
        try form.addField(FieldSpec(.radio, "choice", 0, PdfRect(100, 490, 120, 510), exportValue: "A"))
        try form.addWidget(try XCTUnwrap(form.find("choice")), 0, PdfRect(400, 100, 420, 120), "B")
        let result = try PdfRedactor(document).apply([over()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(PdfForm.read(output).fields.isEmpty)
        XCTAssertTrue(PdfAnnotations.read(output, output.pages[0]).isEmpty)
    }

    func test_markAnnotationsDisappearWhenApplied() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET BT /F1 12 Tf 100 600 Td (public) Tj ET")
        let redactor = PdfRedactor(document)
        let found = try RedactionKit.marksOf(document, 0, "secret words")
        let added = try redactor.addMarks(found, AnnotationInfo(author: "Reviewer"))
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.type, .redact)
        XCTAssertEqual(String(RedactionKit.text(document).prefix(12)), "secret words")

        let marks = redactor.readMarks()
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.page, 0)
        let result = try redactor.applyMarked()
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "public")
        XCTAssertTrue(PdfAnnotations.read(output, output.pages[0]).isEmpty)
        XCTAssertEqual(result.report.annotations, 1)
    }

    func test_markingAloneRemovesNothing() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret) Tj ET")
        _ = try PdfRedactor(document).addMarks(try RedactionKit.marksOf(document, 0, "secret"))
        XCTAssertEqual(RedactionKit.text(document), "secret")
        let bytes = try document.saveRewrite()
        let reopened = try RedactionKit.reopen(bytes)
        XCTAssertEqual(RedactionKit.text(reopened), "secret")
        XCTAssertEqual(PdfRedactor(reopened).readMarks().count, 1)
    }
}
