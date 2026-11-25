using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Ocr/OcrGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output
// again; Swift only reads it.
public class OcrGoldenTests
{
    [Fact]
    public void OcrOutputIsTheGoldenFile()
    {
        Golden.Check("ocr", "ocr-output.txt", OcrGolden.Run(Golden.Input("ocr", "ocr-input.txt")));
    }
}
