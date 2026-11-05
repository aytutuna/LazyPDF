using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Syntax/SyntaxGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1
// to write the outputs again; Swift only reads them.
public class SyntaxGoldenTests
{
    [Fact]
    public void LexerOutputIsTheGoldenFile() =>
        Golden.Check("syntax", "lexer-output.txt", SyntaxGolden.Lexer(Golden.Input("syntax", "lexer-input.txt")));

    [Fact]
    public void NumberFormatIsTheGoldenFile() =>
        Golden.Check("syntax", "number-format-output.txt", SyntaxGolden.Numbers(Golden.Input("syntax", "number-format-input.txt")));
}
