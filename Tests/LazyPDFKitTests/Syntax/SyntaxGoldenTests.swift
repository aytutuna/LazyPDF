import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Syntax/SyntaxGoldenTests.cs: the same cases. The golden files are
// written by the Windows tests.

final class SyntaxGoldenTests: XCTestCase {
    func test_lexerOutputIsTheGoldenFile() throws {
        try Golden.check("syntax", "lexer-output.txt", SyntaxGolden.lexer(try Golden.input("syntax", "lexer-input.txt")))
    }

    func test_numberFormatIsTheGoldenFile() throws {
        try Golden.check("syntax", "number-format-output.txt", SyntaxGolden.numbers(try Golden.input("syntax", "number-format-input.txt")))
    }
}
