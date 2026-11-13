import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfALevelATests.cs: the same cases.

final class PdfALevelATests: XCTestCase {
    private let levels: [PdfALevel] = [.a1a, .a2a, .a3a]

    private func issues(_ file: [UInt8], _ level: PdfALevel) throws -> [PdfAIssue] { try StandardsKit.check(file, level).issues }

    private func convert(_ file: [UInt8], _ level: PdfALevel) throws -> PdfAConversion {
        try PdfAConverter().convert(file, level, StandardsKit.date)
    }

    func test_levelsKnowTheirPartAndConformance() {
        XCTAssertEqual(levels.map { $0.part() }, [1, 2, 3])
        XCTAssertTrue(levels.allSatisfy { $0.conformance() == "A" })
        XCTAssertEqual(levels.map { $0.name() }, ["PDF/A-1a", "PDF/A-2a", "PDF/A-3a"])
        XCTAssertTrue(levels.allSatisfy { $0.needsTags() && $0.needsUnicode() })
        XCTAssertFalse(PdfALevel.a2u.needsTags())
    }

    func test_aTaggedFilePassesEveryLevelA() throws {
        for level in levels { try StandardsKit.assertClean(StandardsKit.tagged(level), level) }
    }

    func test_anUntaggedFileFailsTheStructureRules() throws {
        for level in levels {
            let found = try issues(StandardsKit.compliant(level), level)
            StandardsKit.assertHas(found) { $0.message == PdfAText.noMarkInfo }
            StandardsKit.assertHas(found) { $0.message == PdfAText.noStructTree }
        }
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1a), .a1a), "6.8.3.1")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a2a), .a2a), "6.7.2")
    }

    func test_taggingIssuesNameTheStructureRulesOnlyAtLevelA() throws {
        for level in levels {
            let found = PdfAValidator.taggingIssues(try PdfDocument.open(StandardsKit.compliant(level)), level)
            StandardsKit.assertHas(found) { $0.message == PdfAText.noStructTree }
            XCTAssertTrue(PdfAValidator.taggingIssues(try PdfDocument.open(StandardsKit.tagged(level)), level).isEmpty)
        }
        XCTAssertTrue(PdfAValidator.taggingIssues(try PdfDocument.open(StandardsKit.compliant(.a2b)), .a2b).isEmpty)
    }

    func test_levelBAndUFilesAreNotHeldToTheStructureRules() throws {
        try StandardsKit.assertClean(StandardsKit.compliant(.a2b), .a2b)
        try StandardsKit.assertClean(StandardsKit.compliant(.a2u), .a2u)
    }

    func test_aMissingOrFalseMarkInfoIsReported() throws {
        let missing = try issues(StandardsKit.tagged(.a2a, marked: ""), .a2a)
        XCTAssertEqual(missing.map { $0.message }, [PdfAText.noMarkInfo])
        let no = StandardsKit.tagged(.a2a, marked: "/MarkInfo <</Marked false>>")
        StandardsKit.assertHas(try issues(no, .a2a)) { $0.message == PdfAText.noMarkInfo }
    }

    func test_aMissingLanguageIsReportedUnlessTheTopElementsHaveOne() throws {
        let found = try issues(StandardsKit.tagged(.a3a, lang: ""), .a3a)
        XCTAssertEqual(found.map { $0.message }, [PdfAText.noLanguage])

        let onElement = try StandardsKit.edited(StandardsKit.tagged(.a3a, lang: "")) { d in
            let root = try XCTUnwrap(d.dict(d.catalog, "StructTreeRoot"))
            try XCTUnwrap(d.resolve(root["K"]) as? PdfDictionary)["Lang"] = PdfText.toObject("fr")
        }
        try StandardsKit.assertClean(onElement, .a3a)
    }

    func test_contentOutsideTheTreeIsReportedPerPage() throws {
        let file = StandardsKit.tagged(.a2a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC 1 0 0 rg 130 20 50 50 re f")
        let found = try issues(file, .a2a)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].clause, "6.7.3.1")
        XCTAssertEqual(found[0].where, PdfAText.pageName(1))
    }

    func test_anArtifactMayStandOutsideTheTree() throws {
        let file = StandardsKit.tagged(.a2a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC /Artifact BMC 1 0 0 rg 130 20 50 50 re f EMC")
        try StandardsKit.assertClean(file, .a2a)
    }

    func test_aSequenceTheTreeDoesNotHoldIsReported() throws {
        let file = StandardsKit.tagged(.a1a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC /Span <</MCID 5>> BDC 1 0 0 rg 130 20 50 50 re f EMC")
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1a), "6.8.3.3")
    }

    func test_contentTheParentTreeCannotLeadBackIsReported() throws {
        for level in [PdfALevel.a1a, .a2a, .a3a] {
            let none = try issues(StandardsKit.tagged(level, structParents: ""), level)
            XCTAssertTrue(none.contains { $0.message == PdfAText.noStructParents && $0.where == "Page 1" })
            let wrong = try issues(StandardsKit.tagged(level, parentTree: "[0 [10 0 R]]"), level)
            XCTAssertTrue(wrong.contains { $0.message == PdfAText.parentTreeMismatch })
        }
    }

    func test_aCustomTypeNeedsARoleMapToAStandardOne() throws {
        let bad = StandardsKit.tagged(.a2a, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart")
        XCTAssertEqual(try issues(bad, .a2a).map { $0.message }, [PdfAText.nonStandardType("Chart")])
        try StandardsKit.assertClean(StandardsKit.tagged(.a2a, roleMap: "/RoleMap <</Chart /Figure>>", figureType: "Chart"), .a2a)
    }

    func test_aRoleMapCycleIsNotStandard() throws {
        let file = StandardsKit.tagged(.a2a, roleMap: "/RoleMap <</A /B /B /A>>", figureType: "A")
        StandardsKit.assertHas(try issues(file, .a2a)) { $0.message == PdfAText.nonStandardType("A") }
    }

    func test_typesOfPdf15AreStandardFromPart2Only() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.tagged(.a1a, figureType: "Annot"), .a1a), "6.8.3.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.tagged(.a2a, figureType: "Annot"), .a2a), "6.7.3.2")
    }

    func test_aFigureOrFormulaNeedsAlternateText() throws {
        XCTAssertEqual(try issues(StandardsKit.tagged(.a2a, alt: ""), .a2a).map { $0.message }, [PdfAText.noAlternateText("Figure")])
        try StandardsKit.assertClean(StandardsKit.tagged(.a2a, alt: "/ActualText (square)"), .a2a)
        let formula = StandardsKit.tagged(.a2a, figureType: "Formula", alt: "")
        StandardsKit.assertHas(try issues(formula, .a2a)) { $0.message == PdfAText.noAlternateText("Formula") }
    }

    func test_levelANeedsConformanceAInTheMetadata() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.tagged(.a2b), .a2a), "6.6.4")
    }

    func test_conversionKeepsATaggedFileAndDeclaresTheLevel() throws {
        for level in levels {
            let result = try convert(StandardsKit.tagged(level), level)
            XCTAssertTrue(result.isClean, result.remaining.map { "\($0.clause) \($0.message)" }.joined(separator: "\n"))
            XCTAssertTrue(StandardsKit.latin(try XCTUnwrap(result.bytes)).contains("<pdfaid:conformance>A</pdfaid:conformance>"))
        }
    }

    func test_conversionMarksATreeThatLacksMarkInfo() throws {
        let result = try convert(StandardsKit.tagged(.a2a, marked: ""), .a2a)
        XCTAssertTrue(result.isClean)
        XCTAssertTrue(result.changes.contains(PdfAText.marked))
    }

    func test_conversionRefusesAnUntaggedFileWithoutALanguage() throws {
        for level in levels {
            let result = try convert(StandardsKit.compliant(level), level)
            XCTAssertNil(result.bytes)
            let refusal = try XCTUnwrap(result.refusal)
            XCTAssertTrue(refusal.hasPrefix(level.name()))
            XCTAssertTrue(refusal.contains(PdfAText.noStructTree))
            XCTAssertTrue(refusal.hasSuffix(PdfAText.setLanguageToTag))
        }
    }

    func test_conversionRefusesTaggingThatStillBreaksTheRules() throws {
        let result = try convert(StandardsKit.tagged(.a2a, alt: ""), .a2a)
        XCTAssertNil(result.bytes)
        XCTAssertTrue(try XCTUnwrap(result.refusal).contains(PdfAText.noAlternateText("Figure")))
        let chart = try convert(StandardsKit.tagged(.a2a, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart"), .a2a)
        XCTAssertTrue(try XCTUnwrap(chart.refusal).contains(PdfAText.nonStandardType("Chart")))
    }

    func test_conversionStillRefusesWhenOtherIssuesFillTheReport() throws {
        let pages = 1001
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [\((0..<pages).map { "\(10 + $0) 0 R" }.joined(separator: " "))] /Count \(pages) /MediaBox [0 0 200 300]>>")
        pdf.stream(3, "", "1 0 0 rg 10 10 50 50 re f")
        for i in 0..<pages { pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents 3 0 R>>") }
        let result = try convert(pdf.finish("/Root 1 0 R"), .a2a)
        XCTAssertNil(result.bytes)
        XCTAssertTrue(try XCTUnwrap(result.refusal).hasSuffix(PdfAText.setLanguageToTag))
    }

    func test_conversionTagsAnUntaggedFileThatNamesItsLanguage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Lang (en-US)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let result = try convert(pdf.finish("/Root 1 0 R"), .a2a)
        XCTAssertNil(result.refusal)
        XCTAssertTrue(result.changes.contains(PdfAText.tagged(1)))
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertTrue(document.isTagged)
        XCTAssertFalse(result.remaining.contains { $0.message == PdfAText.noStructTree })
    }
}
