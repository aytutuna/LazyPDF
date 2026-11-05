using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Text/TextGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class TextGoldenTests
{
    [Fact]
    public void TextOutputIsTheGoldenFile()
    {
        Golden.Check("text", "text-output.txt", TextGolden.Run(Golden.Input("text", "text-input.txt")));
    }
}
