#if canImport(CoreText)
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/SystemFontSourceTests.cs. Arial is on every Mac and on iOS.

final class CoreTextFontSourceTests: XCTestCase {
    private let source = CoreTextFontSource()

    private func isFontFile(_ data: [UInt8]) -> Bool {
        guard data.count > 4 else { return false }
        let head = Array(data.prefix(4))
        return head == [0, 1, 0, 0] || head == Array("true".utf8) || head == Array("ttcf".utf8) || head == Array("OTTO".utf8)
    }

    func test_anInstalledFamilyGivesItsFontFile() throws {
        let file = try XCTUnwrap(source.find("Arial", .regular))

        XCTAssertTrue(isFontFile(file.data))
    }

    func test_theBoldFaceIsAnotherFile() throws {
        let regular = try XCTUnwrap(source.find("Arial", .regular))
        let bold = try XCTUnwrap(source.find("Arial", .bold))

        XCTAssertNotEqual(regular.data.count, bold.data.count)
    }

    func test_aFamilyThatIsNotThereGivesNil() {
        XCTAssertNil(source.find("No Such Family Anywhere", .regular))
    }

    func test_thePdfNamesForTheCommonFamiliesAreFound() {
        XCTAssertNotNil(source.find("Helvetica", .regular))
        XCTAssertNotNil(source.find("times new roman", .regular))
    }

    func test_theFileIsOneTheEngineCanEmbedForTurkishLetters() throws {
        let document = try PdfDocument.open(try ApplePdfs.text())
        let font = try PdfFontEmbedder(document, source).add("Arial", .regular, ["Çalışma ğ ş ı İ"])

        XCTAssertNotNil(font)
    }
}
#endif
