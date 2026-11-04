using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeDuplicateTests
{
    private const string Image = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode";
    private const string Mask = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode";

    private static readonly byte[] Pixels = TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 3));

    private const string TwoImages = "q 50 0 0 50 0 0 cm /Im0 Do Q q 50 0 0 50 100 0 cm /Im1 Do Q";
    private const string TwoImageNames = "/XObject <</Im0 5 0 R /Im1 6 0 R>>";

    [Fact]
    public void IdenticalImagesAreWrittenOnce()
    {
        byte[] file = OptimizeKit.Build(TwoImages, TwoImageNames, pdf =>
        {
            pdf.Stream(5, Image, Pixels);
            pdf.Stream(6, Image, Pixels);
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RemoveDuplicates = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(1, OptimizeKit.Count(after, o => OptimizeKit.IsImage(after, o)));
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.RemoveDuplicates).Count);
        var xobjects = after.Dict(after.Pages[0].Resources, "XObject")!;
        Assert.Equal(((PdfReference)xobjects["Im0"]!).Number, ((PdfReference)xobjects["Im1"]!).Number);
    }

    [Fact]
    public void ImagesThatDifferInTheirMaskAreKept()
    {
        byte[] file = OptimizeKit.Build(TwoImages, TwoImageNames, pdf =>
        {
            pdf.Stream(5, Image + " /SMask 7 0 R", Pixels);
            pdf.Stream(6, Image + " /SMask 8 0 R", Pixels);
            pdf.Stream(7, Mask, TestPdf.Deflate(new byte[64]));
            pdf.Stream(8, Mask, TestPdf.Deflate(Enumerable.Repeat((byte)200, 64).ToArray()));
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RemoveDuplicates = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(4, OptimizeKit.Count(after, o => OptimizeKit.IsImage(after, o)));
    }

    [Fact]
    public void MasksThatAreEqualMergeAndTheImagesFollow()
    {
        byte[] file = OptimizeKit.Build(TwoImages, TwoImageNames, pdf =>
        {
            var mask = TestPdf.Deflate(new byte[64]);
            pdf.Stream(5, Image + " /SMask 7 0 R", Pixels);
            pdf.Stream(6, Image + " /SMask 8 0 R", Pixels);
            pdf.Stream(7, Mask, mask);
            pdf.Stream(8, Mask, mask);
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RemoveDuplicates = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(2, OptimizeKit.Count(after, o => OptimizeKit.IsImage(after, o)));
        Assert.Equal(2, result.Steps.Single(s => s.Kind == OptimizeStepKind.RemoveDuplicates).Count);
    }

    [Fact]
    public void IdenticalFontsAreMergedAndTextStays()
    {
        const string font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";
        byte[] file = OptimizeKit.Build("BT /F1 12 Tf 10 100 Td (first) Tj /F2 12 Tf 0 -20 Td (second) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", pdf =>
        {
            pdf.Obj(5, font);
            pdf.Obj(6, font);
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RemoveDuplicates = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(1, OptimizeKit.Count(after, o => o is PdfDictionary d && after.Name(d, "Type") == "Font"));
        Assert.Equal(OptimizeKit.EngineText(file), OptimizeKit.EngineText(result.Bytes));
        Assert.Contains("second", OptimizeKit.PigText(result.Bytes));
    }

    [Fact]
    public void IdenticalPagesStayTwoPages()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        pdf.Stream(5, "", "0 0 10 10 re f");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));
        Assert.Equal(2, OptimizeKit.PigPages(result.Bytes));
    }
}
