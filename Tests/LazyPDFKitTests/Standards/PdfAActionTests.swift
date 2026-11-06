import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAActionTests.cs: the same cases.

final class PdfAActionTests: XCTestCase {
    private func linkWith(_ action: String, _ level: PdfALevel = .a2b) -> [UInt8] {
        StandardsKit.compliant(level, page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A \(action)>>")
        })
    }

    func test_uriAndGoToActionsPass() throws {
        try StandardsKit.assertClean(linkWith("<</S /URI /URI (http://example.com/)>>"))
        try StandardsKit.assertClean(linkWith("<</S /GoTo /D [3 0 R /Fit]>>"))
        try StandardsKit.assertClean(linkWith("<</S /Named /N /NextPage>>"))
    }

    func test_forbiddenActionTypesAreReported() throws {
        for type in ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition"] {
            XCTAssertTrue(try StandardsKit.clauses(linkWith("<</S /\(type)>>")).contains("6.5.1"), type)
        }
    }

    func test_javaScriptIsReportedWhereverItSits() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /JavaScript /JS (app.alert(1))>>")), "6.5.1")
        StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /JavaScript /JS (1)>>", .a1b), .a1b), "6.6.1")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/OpenAction << /S /JavaScript /JS (1) >>")), "6.5.1")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>")), "6.5.1")
    }

    func test_onlyThePageNamedActionsAreAllowed() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /Named /N /Print>>")), "6.5.1")
        StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /Named>>")), "6.5.1")
        for name in ["NextPage", "PrevPage", "FirstPage", "LastPage"] {
            StandardsKit.assertLacks(try StandardsKit.clauses(linkWith("<</S /Named /N /\(name)>>")), "6.5.1")
        }
    }

    func test_aForbiddenActionLaterInAChainIsFound() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /URI /URI (x) /Next [<</S /GoTo /D [3 0 R /Fit]>> <</S /Launch>>]>>")), "6.5.1")
    }

    func test_theCatalogMayNotHaveAdditionalActions() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/AA << /WC << /S /URI /URI (x) >> >>")), "6.5.2")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, catalog: "/AA << /WC << /S /URI /URI (x) >> >>"), .a1b), "6.6.2")
    }

    func test_pageTriggersAreCheckedForTheirActions() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(page: "/AA << /O << /S /JavaScript /JS (1) >> >>")), "6.5.1")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(page: "/AA << /O << /S /URI /URI (x) >> >>")), "6.5.1")
    }

    func test_aPageMayNotHaveAdditionalActionsInPartsTwoAndThree() throws {
        for level in [PdfALevel.a2b, .a3b] {
            let file = StandardsKit.compliant(level, page: "/AA << /O << /S /URI /URI (x) >> >>")
            StandardsKit.assertHas(try StandardsKit.check(file, level).issues, "\(level)") { $0.clause == "6.5.2" && $0.message == PdfAText.pageTriggers }
        }
    }

    func test_partOneHasNoRuleAgainstPageAdditionalActions() throws {
        let file = StandardsKit.compliant(.a1b, page: "/AA << /O << /S /URI /URI (x) >> >>")
        StandardsKit.assertNone(try StandardsKit.check(file, .a1b).issues) { $0.message == PdfAText.pageTriggers }
    }

    func test_partFourLimitsTheKeysOfAPageAdditionalActions() throws {
        StandardsKit.assertHas(try StandardsKit.check(StandardsKit.compliant(.a4, page: "/AA << /O << /S /URI /URI (x) >> >>"), .a4).issues) { $0.clause == "6.6.3" }
        StandardsKit.assertHas(try StandardsKit.check(StandardsKit.compliant(.a4, page: "/AA << /C << /S /URI /URI (x) >> >>"), .a4).issues) { $0.clause == "6.6.3" }
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(.a4, page: "/AA << /E << /S /URI /URI (x) >> /Bl << /S /URI /URI (y) >> >>"), .a4), "6.6.3")
    }
}
