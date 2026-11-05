using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Content/ContentGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class ContentGoldenTests
{
    [Fact]
    public void ContentOutputIsTheGoldenFile()
    {
        Golden.Check("content", "content-output.txt", ContentGolden.Run(Golden.Input("content", "content-input.txt")));
    }
}
