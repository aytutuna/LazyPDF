using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Structure/StructureGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class StructureGoldenTests
{
    [Fact]
    public void StructureOutputIsTheGoldenFile()
    {
        Golden.Check("structure", "structure-output.txt", StructureGolden.Run(Golden.Input("structure", "structure-input.txt")));
    }
}
