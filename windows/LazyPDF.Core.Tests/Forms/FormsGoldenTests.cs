using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Forms/FormsGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output again;
// Swift only reads it.
public class FormsGoldenTests
{
    [Fact]
    public void FormsOutputIsTheGoldenFile()
    {
        Golden.Check("forms", "forms-output.txt", FormsGolden.Run(Golden.Input("forms", "forms-input.txt")));
    }
}
