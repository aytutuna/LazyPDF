using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Filters/FiltersGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it. The binary inputs beside the golden files are made by zlib and by hand.
public class FiltersGoldenTests
{
    [Fact]
    public void FiltersOutputIsTheGoldenFile()
    {
        Golden.Check("filters", "filters-output.txt", FiltersGolden.Run(Golden.Input("filters", "filters-input.txt")));
    }
}
