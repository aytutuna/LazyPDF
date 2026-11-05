using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Fonts/Tables/TablesGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to
// write the outputs again; Swift only reads them.
public class TablesGoldenTests
{
    [Fact]
    public void ToUnicodeCMapIsTheGoldenFile() =>
        Golden.Check("tables", "tounicode-output.txt", TablesGolden.ToUnicode(Golden.Input("tables", "tounicode-input.txt")));
}
