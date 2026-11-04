using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeStripTests
{
    private const string Thumb = "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8";

    [Fact]
    public void ThumbnailsAndApplicationDataGo()
    {
        byte[] file = OptimizeKit.Build("0 0 10 10 re f", "", pdf =>
        {
            pdf.Stream(5, Thumb, new byte[16]);
            pdf.Obj(6, "<</Photo <</LastModified (D:20200101000000Z) /Private 7 0 R>>>>");
            pdf.Stream(7, "", "MARKERPIECE");
        }, pageExtra: "/Thumb 5 0 R /PieceInfo 6 0 R", catalogExtra: "/PieceInfo 6 0 R /ADBE_Private (MARKERPRIVATE)");
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { StripThumbnails = true, StripPieceInfo = true, StripPrivateData = true });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERPIECE"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERPRIVATE"));
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(0, OptimizeKit.Count(after, o => OptimizeKit.IsImage(after, o)));
        Assert.Null(after.Pages[0].Dictionary["Thumb"]);
        Assert.True(result.SizeAfter < result.SizeBefore);
    }

    [Fact]
    public void ApplicationDataStaysWhenNotAsked()
    {
        byte[] file = OptimizeKit.Build("0 0 10 10 re f", "", pdf => pdf.Stream(7, "", "MARKERPIECE"), pageExtra: "/PieceInfo <</X 7 0 R>>");
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off);
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERPIECE"));
    }

    [Fact]
    public void UnusedResourcesAreDropped()
    {
        const string resources = "/Font <</F1 5 0 R /F2 6 0 R>> /XObject <</Fm0 7 0 R /Fm1 8 0 R>> /ExtGState <</G0 <</CA 0.5>>>>";
        byte[] file = OptimizeKit.Build("BT /F1 12 Tf 10 100 Td (kept) Tj ET /G0 gs q /Fm0 Do Q", resources, pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
            pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /UnusedMarkerFont>>");
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</Font <</F3 9 0 R /F4 6 0 R>>>>", "BT /F3 8 Tf (inner) Tj ET");
            pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 5 5 re f");
            pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>");
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { PruneResources = true });
        using var after = PdfDocument.Open(result.Bytes);
        var page = after.Pages[0].Resources!;
        Assert.True(after.Dict(page, "Font")!.ContainsKey("F1"));
        Assert.False(after.Dict(page, "Font")!.ContainsKey("F2"));
        Assert.True(after.Dict(page, "XObject")!.ContainsKey("Fm0"));
        Assert.False(after.Dict(page, "XObject")!.ContainsKey("Fm1"));
        var form = (PdfStream)after.Resolve(after.Dict(page, "XObject")!["Fm0"])!;
        var inner = after.Dict(after.Dict(form.Dictionary, "Resources"), "Font")!;
        Assert.True(inner.ContainsKey("F3"));
        Assert.False(inner.ContainsKey("F4"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "UnusedMarkerFont"));
        Assert.Contains("kept", OptimizeKit.PigText(result.Bytes));
    }

    [Fact]
    public void SharedResourcesKeepWhatEitherPageUses()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources 7 0 R>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>");
        pdf.Stream(5, "", "BT /F1 12 Tf (one) Tj ET");
        pdf.Stream(6, "", "BT /F2 12 Tf (two) Tj ET");
        pdf.Obj(7, "<</Font <</F1 8 0 R /F2 9 0 R /F3 10 0 R>>>>");
        pdf.Obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>");
        pdf.Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { PruneResources = true });
        using var after = PdfDocument.Open(result.Bytes);
        var fonts = after.Dict(after.Pages[0].Resources, "Font")!;
        Assert.True(fonts.ContainsKey("F1"));
        Assert.True(fonts.ContainsKey("F2"));
        Assert.False(fonts.ContainsKey("F3"));
    }

    [Fact]
    public void ResourcesOfAPageWithUnreadableContentAreKept()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] /Resources <</Font <</F1 6 0 R /F2 6 0 R>>>>>>");
        pdf.Stream(4, "", "BT /F1 12 Tf (a) Tj ET");
        pdf.Stream(5, "/Filter /ASCIIHexDecode", "zz not hex");
        pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { PruneResources = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.True(after.Dict(after.Pages[0].Resources, "Font")!.ContainsKey("F2"));
    }
}
