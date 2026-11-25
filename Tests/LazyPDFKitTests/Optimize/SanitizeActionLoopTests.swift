import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeActionLoopTests.cs: the same cases. The C# gives the loop tests ten
// seconds with WaitAsync; here they run in line and the runner's own limit ends one that hangs.

final class SanitizeActionLoopTests: XCTestCase {
    private func withOutline(_ actions: String, _ more: [(number: Int, body: String)] = []) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 6 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(6, "<</Type /Outlines /First 7 0 R /Last 7 0 R /Count 1>>")
        pdf.obj(7, "<</Title (x) /Parent 6 0 R /A 5 0 R>>")
        pdf.obj(5, actions)
        pdf.obj(8, "<</S /JavaScript /JS (app.alert) >>")
        for (number, body) in more { pdf.obj(number, body) }
        return pdf.finish()
    }

    func test_an_action_that_chains_to_itself_is_scanned_and_sanitised() throws {
        let document = try PdfDocument.open(withOutline("<</S /GoTo /D [3 0 R /Fit] /Next 5 0 R>>"))
        let sanitizer = PdfSanitizer(document)
        let start = Date()
        _ = try sanitizer.scan()
        XCTAssertTrue(Date().timeIntervalSince(start) < 10)
        _ = try sanitizer.run(SanitizeOptions())
    }

    func test_a_script_reached_twice_by_the_chain_is_removed_from_every_link() throws {
        for actions in ["<</S /GoTo /D [3 0 R /Fit] /Next [8 0 R 8 0 R]>>", "<</S /GoTo /D [3 0 R /Fit] /Next [9 0 R 10 0 R]>>"] {
            let document = try PdfDocument.open(withOutline(actions, [(9, "<</S /Named /N /NextPage /Next 8 0 R>>"), (10, "<</S /Named /N /PrevPage /Next 8 0 R>>")]))
            let result = try PdfSanitizer(document).run(SanitizeOptions())
            XCTAssertFalse(TestPdf.text(result.bytes).contains("app.alert"), actions)
            XCTAssertEqual(1, SanitizeKit.count(result.removed, .javaScript), actions)
        }
    }

    func test_a_navigation_node_action_is_filtered() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /PresSteps <</Type /NavNode /NA 5 0 R>>>>")
        pdf.obj(5, "<</S /JavaScript /JS (app.alert)>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(TestPdf.text(result.bytes).contains("app.alert"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .javaScript))
    }

    func test_a_script_at_the_end_of_a_long_chain_is_counted_and_follows_the_options() throws {
        var links = (0..<70).map { i in (number: 20 + i, body: "<</S /Named /N /NextPage /Next \(21 + i) 0 R>>") }
        links.append((90, "<</S /JavaScript /JS (app.alert)>>"))
        let document = try PdfDocument.open(withOutline("<</S /GoTo /D [3 0 R /Fit] /Next 20 0 R>>", links))
        let sanitizer = PdfSanitizer(document)
        XCTAssertEqual(1, SanitizeKit.count(try sanitizer.scan(), .javaScript))
        let kept = try sanitizer.run(SanitizeOptions(javaScript: false))
        XCTAssertTrue(TestPdf.text(kept.bytes).contains("app.alert"))
        XCTAssertEqual(1, SanitizeKit.count(kept.kept, .javaScript))
        XCTAssertFalse(TestPdf.text(try sanitizer.run(SanitizeOptions()).bytes).contains("app.alert"))
    }

    func test_an_action_of_an_unknown_type_does_not_hide_the_script_chained_after_it() throws {
        let document = try PdfDocument.open(withOutline("<</S /GoToDp /Next 8 0 R>>"))
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(TestPdf.text(result.bytes).contains("app.alert"))
    }

    func test_a_field_that_is_its_own_parent_is_scanned_and_sanitised() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(5, "<</FT /Tx /T (a) /V (x) /Parent 5 0 R>>")
        let document = try PdfDocument.open(pdf.finish())
        let sanitizer = PdfSanitizer(document)
        let start = Date()
        _ = try sanitizer.scan()
        _ = try sanitizer.run(SanitizeOptions())
        XCTAssertTrue(Date().timeIntervalSince(start) < 20)
    }

    func test_an_action_chained_after_a_removed_one_is_still_counted() throws {
        let document = try PdfDocument.open(withOutline("<</S /URI /URI (http://x.example) /Next 8 0 R>>"))
        let found = try PdfSanitizer(document).scan()
        XCTAssertEqual(1, SanitizeKit.count(found, .javaScript))
        XCTAssertEqual(1, SanitizeKit.count(found, .externalLinks))
    }

    func test_an_action_chained_after_a_removed_one_stays_when_its_kind_is_kept() throws {
        let document = try PdfDocument.open(withOutline("<</S /URI /URI (http://x.example) /Next 8 0 R>>"))
        let result = try PdfSanitizer(document).run(SanitizeOptions(javaScript: false))
        XCTAssertTrue(TestPdf.text(result.bytes).contains("app.alert"))
        XCTAssertFalse(TestPdf.text(result.bytes).contains("x.example"))
        XCTAssertEqual(1, SanitizeKit.count(result.kept, .javaScript))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .externalLinks))
    }

    func test_actions_kept_behind_a_removed_one_all_stay() throws {
        let document = try PdfDocument.open(withOutline("<</S /URI /URI (http://x.example) /Next [8 0 R 9 0 R]>>", [(9, "<</S /JavaScript /JS (second.script)>>")]))
        let result = try PdfSanitizer(document).run(SanitizeOptions(javaScript: false))
        XCTAssertTrue(TestPdf.text(result.bytes).contains("app.alert"))
        XCTAssertTrue(TestPdf.text(result.bytes).contains("second.script"))
        XCTAssertEqual(2, SanitizeKit.count(result.kept, .javaScript))
    }
}
