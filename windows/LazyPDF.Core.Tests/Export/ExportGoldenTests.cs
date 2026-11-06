using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Export/ExportGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class ExportGoldenTests
{
    [Fact]
    public void ExportOutputIsTheGoldenFile()
    {
        Golden.Check("export", "export-output.txt", ExportGolden.Run(Golden.Input("export", "export-input.txt")));
    }
}
