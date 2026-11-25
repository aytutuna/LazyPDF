import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCaseFoldTests.cs: the same cases. What OrdinalIgnoreCase treats as one
// letter: the invariant upper case, with the Turkish letters and the long s left apart. The C# asserts each answer against
// string.Equals first; here the answers are the ones measured with dotnet.

final class RedactCaseFoldTests: XCTestCase {
    private func found(_ needle: String, _ title: String) throws -> Bool {
        let document = try RedactionKit.page("BT ET")
        let info = PdfDictionary()
        info["Title"] = PdfText.toObject(title)
        document.trailer["Info"] = try document.add(info)
        return try RedactionMetadata.scan(document, [needle], false).contains { $0.where == "The document information" }
    }

    func test_lettersAreTheSameOnlyWhenOrdinalIgnoreCaseSaysSo() throws {
        let cases: [(String, String, Bool)] = [
            ("i", "I", true), ("secret", "SECRET", true), ("\u{131}", "I", false), ("\u{131}", "i", false), ("\u{130}", "i", false),
            ("\u{130}", "I", false), ("\u{130}", "\u{130}", true), ("\u{131}", "\u{131}", true), ("\u{17F}", "s", false), ("\u{17F}", "S", false),
            ("s", "\u{17F}", false), ("\u{212A}", "k", false), ("\u{1F80}", "\u{1F88}", true), ("\u{10428}", "\u{10400}", true),
        ]
        for (needle, title, same) in cases {
            let result = try found(needle, "about " + title)
            XCTAssertEqual(result, same, "\(needle.unicodeScalars.map { String($0.value, radix: 16) }) \(title.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
