import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeLoopTests.cs: the same cases.

final class OptimizeLoopTests: XCTestCase {
    private func onePage(_ resources: String, _ content: String, _ more: [(n: Int, body: String)] = []) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources \(resources) /Contents 4 0 R>>")
        pdf.stream(4, "", content)
        for (n, body) in more { pdf.obj(n, body) }
        return pdf.finish()
    }

    func test_a_chain_of_forms_without_resources_that_calls_itself_many_times_does_not_blow_up() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</F 5 0 R>>>> /Contents 4 0 R>>")
        pdf.stream(4, "", "/F Do")
        pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", String(repeating: "/F Do ", count: 50))
        let document = try PdfDocument.open(pdf.finish())

        let start = Date()
        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))

        XCTAssertTrue(Date().timeIntervalSince(start) < 20)
        XCTAssertFalse(result.bytes.isEmpty)
    }

    func test_default_colour_spaces_stay_in_the_resources_though_no_operator_names_them() throws {
        let file = onePage("<</ColorSpace <</DefaultRGB [/ICCBased 5 0 R] /Unused /DeviceGray>>>>", "1 0 0 rg 0 0 10 10 re f",
                           [(5, "<</N 3 /Alternate /DeviceRGB>>")])
        let document = try PdfDocument.open(file)

        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))

        let reopened = try PdfDocument.open(result.bytes)
        let spaces = try XCTUnwrap(reopened.dict(reopened.dict(reopened.pages[0].dictionary, "Resources"), "ColorSpace"))
        XCTAssertTrue(spaces.containsKey("DefaultRGB"))
        XCTAssertFalse(spaces.containsKey("Unused"))
    }
}
