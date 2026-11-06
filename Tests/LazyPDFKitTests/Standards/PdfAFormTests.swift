import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAFormTests.cs: the same cases.

final class PdfAFormTests: XCTestCase {
    private func withForm(_ acroForm: String = "", field: String = "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>>", level: PdfALevel = .a2b) -> [UInt8] {
        StandardsKit.compliant(level, catalog: "/AcroForm << /Fields [9 0 R] \(acroForm) >>", page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Widget /Rect [10 10 90 30] \(field)>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 80 20]", "0 g 0 0 80 20 re S")
        })
    }

    func test_aFieldWithAnAppearanceAndNoScriptsPasses() throws {
        try StandardsKit.assertClean(withForm())
        try StandardsKit.assertClean(withForm(level: .a1b), .a1b)
    }

    func test_needAppearancesIsReported() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withForm("/NeedAppearances true")), "6.4.1")
        StandardsKit.assertContains(try StandardsKit.clauses(withForm("/NeedAppearances true", level: .a1b), .a1b), "6.9")
        StandardsKit.assertLacks(try StandardsKit.clauses(withForm("/NeedAppearances false")), "6.4.1")
    }

    func test_xfaDataIsReported() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withForm("/XFA [(template) 10 0 R]")), "6.4.2")
    }

    func test_additionalActionsOfAFieldAreReported() throws {
        let field = "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /AA << /K << /S /URI /URI (x) >> >>"
        for (level, clause) in [(PdfALevel.a1b, "6.6.2"), (.a2b, "6.4.1"), (.a3b, "6.4.1")] {
            StandardsKit.assertContains(try StandardsKit.clauses(withForm(field: field, level: level), level), clause)
            StandardsKit.assertLacks(try StandardsKit.clauses(withForm(field: field, level: level), level), "6.5.2")
        }
    }

    func test_partFourLetsAFieldHaveAdditionalActions() throws {
        let file = withForm(field: "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /AA << /K << /S /URI /URI (x) >> >>", level: .a4)
        StandardsKit.assertNone(try StandardsKit.check(file, .a4).issues) { $0.clause == "6.4.1" || $0.clause == "6.5.2" || $0.clause == "6.6.3" }
    }

    func test_aWidgetMayNotHaveAnActionEvenAPermittedOne() throws {
        for (level, clause) in [(PdfALevel.a1b, "6.6.1"), (.a2b, "6.4.1"), (.a3b, "6.4.1"), (.a4, "6.4.1")] {
            let file = withForm(field: "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /A << /S /URI /URI (x) >>", level: level)
            StandardsKit.assertHas(try StandardsKit.check(file, level).issues, "\(level)") { $0.clause == clause && $0.message == PdfAText.widgetAction }
        }
    }

    func test_fieldsAreFoundThroughTheirKids() throws {
        let file = StandardsKit.compliant(catalog: "/AcroForm << /Fields [9 0 R] >>", extra: { pdf in
            pdf.obj(9, "<</T (g) /Kids [11 0 R]>>")
            pdf.obj(11, "<</T (a) /FT /Tx /Parent 9 0 R /AA << /K << /S /URI /URI (x) >> >>>>")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.4.1")
    }
}
