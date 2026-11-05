import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/LexerToleranceTests.cs: the same cases, except
// SpacesAfterTheStreamKeywordAreNotData, which opens a document and comes with the Document layer (the
// lexer's side of it is in the golden file).

final class LexerToleranceTests: XCTestCase {
    private func read(_ text: String, allowStream: Bool = true) throws -> PdfObject {
        try PdfLexer(PdfArrayBytes(Latin1.bytes(text))).readObject(allowStream: allowStream)
    }

    private func assertDamaged(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(text), file: file, line: line) { error in
            XCTAssertTrue(error is PdfReadException, file: file, line: line)
        }
    }

    func test_malformedNumbersReadAsTheirFirstValidPart() throws {
        let cases = [("--5", "-5"), ("1.2.3", "1.2"), ("5-3", "5"), ("-", "0"), (".", "0"), ("+.5", "+.5"), ("12", "12")]
        for (token, expected) in cases {
            let array = try XCTUnwrap(try read("[\(token)]") as? PdfArray)
            XCTAssertEqual(array.items.count, 1, token)
            let number = try XCTUnwrap(array.items.first as? PdfNumber)
            XCTAssertEqual(number.text, expected, token)
        }
    }

    func test_arrayAndDictionaryNeverClosedStopAtEndobj() throws {
        let array = try XCTUnwrap(try read("[1 2 3\nendobj\n") as? PdfArray)
        XCTAssertEqual(array.items.count, 3)
        let dictionary = try XCTUnwrap(try read("<</A 1 /B [2\nendobj\n") as? PdfDictionary)
        XCTAssertEqual(dictionary.count, 2)
        assertDamaged("<</A 1 /B ")
        assertDamaged("[1 2")
    }

    func test_junkWhereAKeyShouldBeIsReadPast() throws {
        let dictionary = try XCTUnwrap(try read("<</A 1 (junk) 2 3 /B 4>>") as? PdfDictionary)
        XCTAssertEqual(dictionary.entries.map { $0.key }, ["A", "B"])
        XCTAssertEqual((dictionary["B"] as? PdfNumber)?.text, "4")
    }

    func test_strayCharactersInAHexStringAreIgnored() throws {
        let text = try XCTUnwrap(try read("<41 4x2 zz 43>") as? PdfString)
        XCTAssertEqual(Latin1.string(text.bytes), "ABC")
    }
}
