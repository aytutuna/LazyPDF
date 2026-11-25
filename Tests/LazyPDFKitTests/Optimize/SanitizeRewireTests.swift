import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeRewireTests.cs: the same cases (chains of actions where something
// goes and something stays). The C# gives the first test twenty seconds with WaitAsync; here it runs in line and the
// elapsed time is checked. The PdfPig page count has no twin; the engine's own stands in for it.

final class SanitizeRewireTests: XCTestCase {
    private func linked(_ catalogExtra: String, _ annots: String, _ more: [(number: Int, body: String)]) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [\(annots)]>>")
        for (number, body) in more { pdf.obj(number, body) }
        return pdf.finish()
    }

    private func run(_ file: [UInt8], _ options: SanitizeOptions) throws -> SanitizeResult {
        let document = try PdfDocument.open(file)
        return try PdfSanitizer(document).run(options)
    }

    func test_survivorsBehindAGoneActionThatLoopsBackStayBounded() throws {
        let count = 3000
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 5 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(5, "<</S /URI /URI (http://x.example) /Next [\((10..<10 + count).map { "\($0) 0 R" }.joined(separator: " "))]>>")
        for i in 0..<count { pdf.obj(10 + i, "<</S /Named /N /NextPage /Next 5 0 R>>") }
        let document = try PdfDocument.open(pdf.finish())
        let sanitizer = PdfSanitizer(document)
        let start = Date()
        _ = try sanitizer.scan()
        let result = try sanitizer.run(SanitizeOptions())
        XCTAssertTrue(Date().timeIntervalSince(start) < 40)
        XCTAssertTrue(result.bytes.count < 6_000_000)
        XCTAssertFalse(TestPdf.text(result.bytes).contains("x.example"))
        XCTAssertEqual(1, try PdfDocument.open(result.bytes).pages.count)
    }

    func test_actionsAfterAScriptInTheDocumentScriptTreeAreCountedAndFiltered() throws {
        let source = linked("/Names <</JavaScript <</Names [(a) 5 0 R]>>>>", "", [
            (5, "<</S /JavaScript /JS (MARKERJS1) /Next 6 0 R>>"),
            (6, "<</S /Launch /F (MARKERLAUNCH.exe)>>"),
        ])
        let document = try PdfDocument.open(source)
        XCTAssertEqual(1, SanitizeKit.count(try PdfSanitizer(document).scan(), .launchActions))
        let kept = try run(source, SanitizeOptions(javaScript: false))
        XCTAssertTrue(try OptimizeKit.everywhere(kept.bytes, "MARKERJS1"))
        XCTAssertFalse(try OptimizeKit.everywhere(kept.bytes, "MARKERLAUNCH"))
        XCTAssertEqual(1, SanitizeKit.count(kept.removed, .launchActions))
        XCTAssertEqual(1, SanitizeKit.count(kept.kept, .javaScript))
    }

    func test_aLaunchBehindAScriptTreeThatGoesIsReportedAsGone() throws {
        let source = linked("/Names <</JavaScript <</Names [(a) 5 0 R]>>>>", "", [
            (5, "<</S /JavaScript /JS (MARKERJS1) /Next 6 0 R>>"),
            (6, "<</S /Launch /F (MARKERLAUNCH.exe)>>"),
        ])
        let result = try run(source, SanitizeOptions(launchActions: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERLAUNCH"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .launchActions))
        XCTAssertEqual(0, SanitizeKit.count(result.kept, .launchActions))
    }

    func test_survivorsCarriedByACopyLeaveTheSharedActionAlone() throws {
        let source = linked("", "5 0 R 6 0 R", [
            (5, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 7 0 R>>"),
            (6, "<</Type /Annot /Subtype /Link /Rect [20 0 29 9] /A 8 0 R>>"),
            (7, "<</S /URI /URI (http://x.example) /Next [8 0 R 9 0 R]>>"),
            (8, "<</S /Named /N /NextPage>>"),
            (9, "<</S /JavaScript /JS (MARKERJS1) /Next 8 0 R>>"),
        ])
        let result = try run(source, SanitizeOptions(javaScript: false))
        let after = try PdfDocument.open(result.bytes)
        let annots = try XCTUnwrap(after.array(after.pages[0].dictionary, "Annots"))
        let first = try XCTUnwrap(after.dict(after.resolve(annots.items[0]) as? PdfDictionary, "A"))
        let second = try XCTUnwrap(after.dict(after.resolve(annots.items[1]) as? PdfDictionary, "A"))
        XCTAssertFalse(second.containsKey("Next"))
        XCTAssertEqual("Named", after.name(first, "S"))
        let next = try XCTUnwrap(after.dict(first, "Next"))
        XCTAssertEqual("JavaScript", after.name(next, "S"))
        XCTAssertEqual("Named", after.name(try XCTUnwrap(after.dict(next, "Next")), "S"))
    }

    func test_aRenditionScriptRemovedByTheOtherOptionIsNotReportedAsKept() throws {
        let source = linked("/OpenAction 5 0 R", "", [(5, "<</S /Rendition /OP 0 /JS (MARKERJS1)>>")])
        let scriptsOff = try run(source, SanitizeOptions(javaScript: false))
        XCTAssertFalse(try OptimizeKit.everywhere(scriptsOff.bytes, "MARKERJS1"))
        XCTAssertEqual(0, SanitizeKit.count(scriptsOff.kept, .javaScript))
        XCTAssertEqual(1, SanitizeKit.count(scriptsOff.removed, .javaScript))
        let launchOff = try run(source, SanitizeOptions(launchActions: false))
        XCTAssertEqual(0, SanitizeKit.count(launchOff.kept, .launchActions))
        XCTAssertEqual(1, SanitizeKit.count(launchOff.removed, .launchActions))
    }
}
