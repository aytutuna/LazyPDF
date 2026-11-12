import XCTest
import LazyPDFKit
@testable import LazyPDFApp

@MainActor
final class OpenFormNoticeTests: XCTestCase {
    private func formPdf(_ field: String) throws -> PdfDocument {
        let pdf = "%PDF-1.7\n1 0 obj\n<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>\nendobj\n"
            + "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n"
            + "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R]>>\nendobj\n"
            + "4 0 obj\n<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [10 10 100 30] /P 3 0 R \(field)>>\nendobj\n"
            + "trailer\n<</Root 1 0 R /Size 5>>\n%%EOF\n"
        return try PdfDocument.open(Array(pdf.utf8))
    }

    func test_aDynamicXfaFormIsExplained() async throws {
        let document = try PdfDocument.open(FormPdfs.dynamicXfa())

        XCTAssertEqual(AppViewModel.formNotice(document)?.1, FormText.dynamicXfa)
    }

    func test_aScriptThatCannotRunIsReported() async throws {
        let document = try formPdf(#"/AA <</K <</S /JavaScript /JS (app.alert\(1\))>>>>"#)

        XCTAssertEqual(AppViewModel.formNotice(document)?.0, L10n.t("Form scripts not run"))
    }

    func test_aBuiltInFormatScriptIsQuiet() async throws {
        let document = try formPdf(#"/AA <</F <</S /JavaScript /JS (AFNumber_Format\(2, 0, 0, 0, "", true\))>>>>"#)

        XCTAssertNil(AppViewModel.formNotice(document))
    }

    func test_aPlainFormIsQuiet() async throws {
        XCTAssertNil(AppViewModel.formNotice(try formPdf("")))
    }
}
