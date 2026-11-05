using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Pages/PagesGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class PagesGoldenTests
{
    [Fact]
    public void PagesOutputIsTheGoldenFile()
    {
        Golden.Check("pages", "pages-output.txt", PagesGolden.Run(Golden.Input("pages", "pages-input.txt")));
    }
}
