using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Optimize/OptimizeGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class OptimizeGoldenTests
{
    [Fact]
    public void OptimizeOutputIsTheGoldenFile()
    {
        Golden.Check("optimize", "optimize-output.txt", OptimizeGolden.Run(Golden.Input("optimize", "optimize-input.txt")));
    }
}
