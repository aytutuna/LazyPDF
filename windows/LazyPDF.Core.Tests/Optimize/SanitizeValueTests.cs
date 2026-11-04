using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Values and file names that sit above or below the node a sanitizer first looks at.
public class SanitizeValueTests
{
    private static SanitizeResult Run(byte[] file, SanitizeOptions? options = null)
    {
        using var document = PdfDocument.Open(file);
        return new PdfSanitizer(document).Run(options ?? new SanitizeOptions());
    }

    private static byte[] Page(string catalogExtra, string annots, params (int Number, string Body)[] more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Annots [{annots}]>>");
        foreach (var (number, body) in more) pdf.Obj(number, body);
        return pdf.Finish();
    }

    [Fact]
    public void AValueTheParentPassesDownIsCleared()
    {
        byte[] file = Page("/AcroForm <</Fields [4 0 R]>>", "5 0 R",
            (4, "<</T (p) /FT /Tx /V (MARKERFORM) /Kids [5 0 R]>>"),
            (5, "<</Type /Annot /Subtype /Widget /T (c) /Parent 4 0 R /Rect [10 100 150 120] /P 3 0 R>>"));
        var result = Run(file);
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERFORM"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.FormData));
        using var after = PdfDocument.Open(result.Bytes);
        Assert.True(string.IsNullOrEmpty(PdfForm.Read(after).Find("p.c")!.Value));
    }

    [Fact]
    public void AFileUrlInAUrlSpecificationIsAPath()
    {
        byte[] file = Page("", "5 0 R",
            (5, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 9 9] /FS <</Type /Filespec /FS /URL /F (file:///C:/Users/MARKERNAME/secret/a.pdf)>>>>"));
        var result = Run(file, new SanitizeOptions { EmbeddedFiles = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERNAME"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "a.pdf"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.FilePaths));
    }

    [Fact]
    public void ASubmitAddressWithoutASpecificationIsNotAPath()
    {
        const string Address = "https://forms.example/app/x/post";
        byte[] file = Page("/OpenAction 5 0 R", "", (5, $"<</S /SubmitForm /F ({Address})>>"));
        var result = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, Address));
        Assert.Equal(0, SanitizeKit.Count(result.Removed, SanitizeItem.FilePaths));
    }

    [Fact]
    public void AnOpiFileGivenAsASpecificationDictionaryIsCut()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im0 5 0 R>>>> /Contents 6 0 R>>");
        pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 " +
            "/OPI <</2.0 <</Type /OPI /Version 2.0 /F <</F (/home/MARKERUSER/pic.tif)>>>>>>", "H");
        pdf.Stream(6, "", "q 10 0 0 10 0 0 cm /Im0 Do Q");
        var result = Run(pdf.Finish());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERUSER"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "pic.tif"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.FilePaths));
    }

    [Fact]
    public void TheAppearanceOfASignatureKidBelowAKidIsRemoved()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [8 0 R]>>");
        pdf.Obj(4, "<</FT /Sig /T (s) /V 6 0 R /Kids [7 0 R]>>");
        pdf.Obj(6, "<</Type /Sig /ByteRange [0 10 20 30] /Contents <3082010a> /Name (MARKERSIGNER)>>");
        pdf.Obj(7, "<</T (a) /Parent 4 0 R /Kids [8 0 R]>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Parent 7 0 R /Rect [10 10 110 50] /P 3 0 R /AP <</N 9 0 R>>>>");
        pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 40]", "BT 0 0 Td (MARKERSIGAP) Tj ET");
        var result = Run(pdf.Finish());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERSIGAP"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERSIGNER"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.Signatures));
    }
}
