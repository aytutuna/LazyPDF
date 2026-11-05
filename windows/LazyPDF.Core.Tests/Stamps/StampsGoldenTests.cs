using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Stamps/StampsGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class StampsGoldenTests
{
    [Fact]
    public void StampsOutputIsTheGoldenFile()
    {
        Golden.Check("stamps", "stamps-output.txt", StampsGolden.Run(Golden.Input("stamps", "stamps-input.txt")));
    }
}
