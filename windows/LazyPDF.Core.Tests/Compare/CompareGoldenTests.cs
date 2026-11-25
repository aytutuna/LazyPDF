using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Compare/CompareGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class CompareGoldenTests
{
    [Fact]
    public void CompareOutputIsTheGoldenFile()
    {
        Golden.Check("compare", "compare-output.txt", CompareGolden.Run(Golden.Input("compare", "compare-input.txt")));
    }
}
