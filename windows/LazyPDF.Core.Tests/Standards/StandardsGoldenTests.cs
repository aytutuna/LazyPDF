using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Standards/StandardsGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class StandardsGoldenTests
{
    [Fact]
    public void StandardsOutputIsTheGoldenFile()
    {
        Golden.Check("standards", "standards-output.txt", StandardsGolden.Run(Golden.Input("standards", "standards-input.txt")));
    }
}
