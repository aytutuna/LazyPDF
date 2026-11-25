import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactValueTests.cs: the same cases.

final class RedactValueTests: XCTestCase {
    private func blank() throws -> PdfDocument { try RedactionKit.page("BT /F1 12 Tf 100 700 Td (page text) Tj ET") }

    @discardableResult
    private func note(_ document: PdfDocument, _ contents: String) throws -> PdfAnnotation {
        try PdfAnnotationWriter(document).addNote(document.pages[0], PdfRect(400, 100, 420, 120), AnnotationInfo(author: "Reviewer", contents: contents))
    }

    private func contents(_ document: PdfDocument) throws -> String? {
        let left = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(left.count, 1)
        return left.first?.contents
    }

    func test_commentTextIsFoundAndRewrittenWithTheRestKept() throws {
        let document = try blank()
        try note(document, "Mail jane.doe@example.com before friday")
        let found = try RedactionFinder.findInValues(document, .email)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "jane.doe@example.com")
        XCTAssertEqual(found.first?.source, .comment)

        let result = try PdfRedactor(document).apply([], nil, found)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(try contents(output), "Mail  before friday")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "jane.doe@example.com"))
        XCTAssertTrue(result.verification.isClean)
        XCTAssertEqual(result.report.pages.count, 1)
        XCTAssertEqual(result.report.pages.first?.values, 1)
        XCTAssertFalse(result.report.pages[0].isEmpty)
    }

    func test_overlappingHitsFromTwoFindersAreRewrittenAsTheirUnion() throws {
        let document = try blank()
        try note(document, "Mail jane.doe@example.com before friday")
        let found = try RedactionFinder.findInValues(document, .email) + RedactionFinder.findWordsInValues(document, ["doe"])
        XCTAssertEqual(found.count, 2)
        let result = try PdfRedactor(document).apply([], nil, found)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), "Mail  before friday")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "example.com"))
    }

    func test_overlayTextReplacesTheMatch() throws {
        let document = try blank()
        try note(document, "call 555-0147-9988 now")
        let found = try RedactionFinder.findWordsInValues(document, ["555-0147-9988"])
        var options = RedactionOptions()
        options.overlayText = "[x]"
        let result = try PdfRedactor(document).apply([], options, found)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), "call [x] now")
    }

    func test_richTextAndTheSubjectLoseTheWordsToo() throws {
        let document = try blank()
        let n = try note(document, "the secret plan")
        n.dictionary["RC"] = PdfText.toObject("<body><p>the secret plan</p></body>")
        n.dictionary["Subj"] = PdfText.toObject("secret")
        let found = try RedactionFinder.findWordsInValues(document, ["secret"])
        let result = try PdfRedactor(document).apply([], nil, found)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "secret"))
        XCTAssertTrue(result.verification.isClean)
    }

    func test_freeTextIsDrawnAgainWithoutTheMatch() throws {
        let document = try blank()
        try PdfAnnotationWriter(document).addFreeText(document.pages[0], PdfRect(100, 400, 300, 440), "pay IBAN DE89 3704 0044 0532 0130 00 today",
                                                      info: AnnotationInfo(author: "A"))
        let found = try RedactionFinder.findInValues(document, .iban)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "DE89 3704 0044 0532 0130 00")
        let result = try PdfRedactor(document).apply([], nil, found)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), "pay IBAN  today")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "0532 0130"))
        XCTAssertTrue(result.verification.isClean)
    }

    func test_removedFreeTextDoesNotHideALaterHitOnThePage() throws {
        let document = try blank()
        try PdfAnnotationWriter(document).addFreeText(document.pages[0], PdfRect(100, 400, 300, 440), "secret", info: AnnotationInfo(author: "A"))
        try note(document, "mail jane.doe@example.com")
        let found = try RedactionFinder.findWordsInValues(document, ["secret", "jane.doe@example.com"])
        XCTAssertEqual(found.count, 2)
        var options = RedactionOptions()
        options.overlayText = "\u{1F600}"
        let result = try PdfRedactor(document).apply([], options, found)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "jane.doe@example.com"))
        XCTAssertTrue(result.verification.isClean)
        XCTAssertEqual(result.report.pages.first?.values, 2)
        XCTAssertEqual(result.report.pages.first?.valuesWhole, 1)
        XCTAssertTrue(result.report.description.contains("removed whole"))
    }

    func test_fieldValueIsRewrittenAndItsAppearanceDrawnAgain() throws {
        let document = try blank()
        let form = PdfForm.read(document)
        try form.addField(FieldSpec(.text, "note", 0, PdfRect(100, 490, 400, 510), value: "ssn 123-45-6789 on file"))
        let found = try RedactionFinder.findInValues(document, .usSocialSecurity)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.source, .field)

        let result = try PdfRedactor(document).apply([], nil, found)
        let output = try RedactionKit.open(result)
        let fields = PdfForm.read(output).fields
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.value, "ssn  on file")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "123-45-6789"))
        XCTAssertTrue(result.verification.isClean)
        XCTAssertEqual(result.report.pages.first?.values, 1)
    }

    func test_valueChangedSinceTheSearchIsLeftAlone() throws {
        let document = try blank()
        try note(document, "abc secret def")
        var found = try RedactionFinder.findWordsInValues(document, ["secret"])
        for i in found.indices { found[i].start += 1 }
        let result = try PdfRedactor(document).apply([], nil, found)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), "abc secret def")
        XCTAssertTrue(result.report.pages.isEmpty)
    }

    func test_regexAndWholeWordSearchSeveralHitsInOneValue() throws {
        let document = try blank()
        try note(document, "cat concat cat")
        XCTAssertEqual(try RedactionFinder.findWordsInValues(document, ["cat"]).count, 2)
        XCTAssertEqual(try RedactionFinder.findWordsInValues(document, ["cat"], false).count, 3)
        let found = try RedactionFinder.findRegexInValues(document, "c[a]t")
        let result = try PdfRedactor(document).apply([], nil, found)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), " con ")
    }

    func test_valuesAndMarksWorkTogether() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        try note(document, "secret note")
        let marks = try RedactionKit.marksOf(document, 0, "secret words")
        let found = try RedactionFinder.findWordsInValues(document, ["secret"])
        let result = try PdfRedactor(document).apply(marks, nil, found)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "secret note"))
        XCTAssertTrue(result.verification.isClean)
        XCTAssertEqual(try contents(try RedactionKit.open(result)), " note")
    }
}
