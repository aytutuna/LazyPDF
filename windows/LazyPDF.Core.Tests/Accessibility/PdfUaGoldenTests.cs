using Xunit;

namespace LazyPDF.Core.Tests;

// Run with LAZYPDF_WRITE_GOLDEN=1 to write the output again; the Swift twin only reads it.
public class PdfUaGoldenTests
{
    [Fact]
    public void PdfUaOutputIsTheGoldenFile()
    {
        Golden.Check("pdfua", "pdfua-output.txt", PdfUaGolden.Run(Golden.Input("pdfua", "pdfua-input.txt")));
    }
}
