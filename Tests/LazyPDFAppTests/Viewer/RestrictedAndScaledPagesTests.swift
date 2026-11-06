import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the page size test of windows/LazyPDF.App.Tests/RestrictedAndScaledPagesTests.cs: /UserUnit pages keep their size.
// The restricted AES-256 file that is drawn although it was opened without the owner, the region of a UserUnit page, and the
// repeated loads all go through a renderer, so they move to the PDFKit renderer's tests.

final class RestrictedAndScaledPagesTests: XCTestCase {
    // A page of 100 by 100 units, /UserUnit 2 (so 200 points), filled with black.
    private func blackPage(_ unit: Int) -> [UInt8] {
        let content = "0 g 0 0 100 100 re f"
        let text = "%PDF-1.7\n"
            + "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /UserUnit \(unit) /Contents 4 0 R >>\nendobj\n"
            + "4 0 obj\n<< /Length \(content.count) >>\nstream\n\(content)\nendstream\nendobj\n"
            + "trailer\n<< /Root 1 0 R /Size 5 >>\n%%EOF\n"
        return Array(text.utf8)
    }

    // TODO: the PDFKit renderer piece ports the renderer.pageSize test and applies UserUnit there; PDFKit page bounds ignore it.
    func test_theEngineSizeOfAUserUnitPageIsItsRealSize() throws {
        let session = try PdfEditSession.open(blackPage(2))

        let sizes = PageSurfaceState.pageSizes(session.document, nil)

        XCTAssertEqual(sizes[0].width, 200, accuracy: 0.01)
        XCTAssertEqual(sizes[0].height, 200, accuracy: 0.01)
    }
}
