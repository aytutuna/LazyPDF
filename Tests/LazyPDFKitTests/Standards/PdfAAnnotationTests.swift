import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAAnnotationTests.cs: the same cases.

final class PdfAAnnotationTests: XCTestCase {
    private let square = "/Subtype /Square /F 4 /AP <</N 10 0 R>>"

    private func withAnnotation(_ annotation: String, _ level: PdfALevel = .a2b, appearance: Bool = true) -> [UInt8] {
        StandardsKit.compliant(level, page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Rect [10 10 50 50] \(annotation)>>")
            if appearance { pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f") }
        })
    }

    func test_anAnnotationWithAnAppearanceAndThePrintFlagPasses() throws {
        try StandardsKit.assertClean(withAnnotation(square))
        try StandardsKit.assertClean(withAnnotation(square, .a1b), .a1b)
    }

    func test_forbiddenTypesAreReported() throws {
        for type in ["Sound", "Movie", "Screen", "3D", "Bogus"] {
            XCTAssertTrue(try StandardsKit.clauses(withAnnotation("/Subtype /\(type) /F 4 /AP <</N 10 0 R>>")).contains("6.3.1"), type)
        }
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Sound /F 4 /AP <</N 10 0 R>>", .a1b), .a1b), "6.5.2")
    }

    func test_typesFromPdf15AreReportedInPart1Only() throws {
        let caret = "/Subtype /Caret /F 4 /AP <</N 10 0 R>>"
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation(caret, .a1b), .a1b), "6.5.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(withAnnotation(caret)), "6.3.1")
    }

    func test_aMissingNormalAppearanceIsReportedButNotForLinksOrPopups() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F 4", appearance: false)), "6.3.3")
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F 4 /AP <</D 10 0 R>>")), "6.3.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(withAnnotation("/Subtype /Link /F 4 /Border [0 0 0]", appearance: false)), "6.3.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(withAnnotation("/Subtype /Popup", appearance: false)), "6.3.3")
    }

    func test_anAppearanceDictionaryMayOnlyHoldN() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F 4 /AP <</N 10 0 R /D 10 0 R>>")), "6.3.3")
    }

    func test_theNormalAppearanceOfAButtonIsADictionaryAndOtherwiseAStream() throws {
        let widget = "/Subtype /Widget /FT /Btn /F 4"
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("\(widget) /AP <</N 10 0 R>>")), "6.3.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(withAnnotation("\(widget) /AP <</N <</Yes 10 0 R /Off 10 0 R>>>>")), "6.3.3")
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Widget /FT /Tx /F 4 /AP <</N <</Yes 10 0 R>>>>")), "6.3.3")
    }

    func test_printAndVisibilityFlagsAreChecked() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F 0 /AP <</N 10 0 R>>")), "6.3.2")
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /AP <</N 10 0 R>>")), "6.3.2")
        for hidden in [1, 2, 32] {
            StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F \(4 | hidden) /AP <</N 10 0 R>>")), "6.3.2")
        }
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation("/Subtype /Square /F 0 /AP <</N 10 0 R>>", .a1b), .a1b), "6.5.3")
    }

    func test_theAppearanceStreamIsWalkedForColour() throws {
        let file = StandardsKit.compliant(page: "/Annots [9 0 R]", content: "", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Rect [10 10 50 50] /Subtype /Square /F 4 /AP <</N 10 0 R>>>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f")
        }, intents: "")
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.2.4.3" && $0.where.hasPrefix("Page 1, annotation 1") }
    }

    func test_aFileAttachmentIsAllowedFromPart2ButNotInPart1OrPart4() throws {
        let attach = "/Subtype /FileAttachment /F 4 /AP <</N 10 0 R>>"
        StandardsKit.assertLacks(try StandardsKit.clauses(withAnnotation(attach)), "6.3.1")
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation(attach, .a1b), .a1b), "6.5.2")
        StandardsKit.assertContains(try StandardsKit.clauses(withAnnotation(attach, .a4), .a4), "6.3.1")
    }
}
