using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeKeepTests
{
    [Fact]
    public void A_pdfa_1_file_is_not_given_object_streams()
    {
        using var document = PdfDocument.Open(StandardsKit.Compliant(PdfALevel.A1b));

        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));

        Assert.DoesNotContain("/ObjStm", TestPdf.Text(result.Bytes));
    }

    [Fact]
    public void A_jpeg_with_a_decode_array_is_left_in_colour_when_made_gray()
    {
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Decode [1 0 1 0 1 0] /Filter /DCTDecode", OptimizeKit.TinyJpeg));
        using var document = PdfDocument.Open(file);

        var result = new PdfOptimizer(document, new OptimizeFakeCodec()).Run(OptimizeOptions.For(OptimizePreset.Balanced) with { Grayscale = true });

        using var after = PdfDocument.Open(result.Bytes);
        var image = OptimizeKit.Image(after);
        Assert.Equal("DeviceRGB", after.Name(image.Dictionary, "ColorSpace"));
        Assert.True(image.Dictionary.ContainsKey("Decode"));
    }
}
