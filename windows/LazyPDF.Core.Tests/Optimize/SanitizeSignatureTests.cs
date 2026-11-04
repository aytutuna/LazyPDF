using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeSignatureTests
{
    private static byte[] Signed()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R] /SigFlags 3>> /Perms <</DocMDP 5 0 R>> /DSS <</OCSPs [7 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Annots [4 0 R]>>");
        pdf.Obj(4, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Sign1) /V 5 0 R /Rect [10 10 110 50] /P 3 0 R /AP <</N 8 0 R>>>>");
        pdf.Obj(5, "<</Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 10 20 30] /Contents <3082010a3082010a> " +
            "/Name (MARKERSIGNER) /Reason (MARKERREASON) /Location (MARKERPLACE) /M (D:20240101000000Z)>>");
        pdf.Stream(6, "", "0 g 10 10 20 20 re f");
        pdf.Stream(7, "", "MARKEROCSP");
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 100 40]", "BT 0 0 Td (MARKERSIGAP) Tj ET");
        return pdf.Finish();
    }

    private static readonly string[] Markers = ["MARKERSIGNER", "MARKERREASON", "MARKERPLACE", "MARKEROCSP", "MARKERSIGAP", "ByteRange", "DocMDP", "SigFlags"];

    [Fact]
    public void TheSanitizerLeavesNoSignatureDictionaryDssPermsOrAppearance()
    {
        byte[] file = Signed();
        foreach (string marker in Markers) Assert.True(OptimizeKit.Everywhere(file, marker), marker);
        using var document = PdfDocument.Open(file);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        foreach (string marker in Markers) Assert.False(OptimizeKit.Everywhere(result.Bytes, marker), marker);
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.Signatures));
        using var after = PdfDocument.Open(result.Bytes);
        Assert.False(after.IsSigned);
        Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
    }

    [Fact]
    public void ScanListsTheSignature()
    {
        using var document = PdfDocument.Open(Signed());
        Assert.Equal(1, SanitizeKit.Count(new PdfSanitizer(document).Scan(), SanitizeItem.Signatures));
    }

    [Fact]
    public void TheOptimizerKeepsTheLookOfASignedField()
    {
        using var document = PdfDocument.Open(Signed());
        var result = new PdfOptimizer(document).Run(new OptimizeOptions());
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERSIGAP"));
    }

    [Fact]
    public void AFieldTypeMarksTheSignatureWhenTheValueHasNeitherTypeNorByteRange()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>");
        pdf.Obj(4, "<</FT /Sig /T (sig) /Kids [5 0 R] /V 6 0 R>>");
        pdf.Obj(5, "<</Type /Annot /Subtype /Widget /Parent 4 0 R /Rect [0 0 0 0] /P 3 0 R>>");
        pdf.Obj(6, "<</Filter /Adobe.PPKLite /SubFilter /adbe.x509.rsa_sha1 /Cert (x) /Contents <3082> /Name (MARKERSIGNER)>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERSIGNER"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.Signatures));
    }

    [Fact]
    public void ADocumentTimeStampWithoutAFieldGoesToo()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R]>>");
        pdf.Obj(4, "<</Type /Annot /Subtype /Widget /FT /Sig /T (ts) /V 5 0 R /Rect [0 0 0 0] /P 3 0 R>>");
        pdf.Obj(5, "<</Type /DocTimeStamp /Filter /Adobe.PPKLite /SubFilter /ETSI.RFC3161 /ByteRange [0 1 2 3] /Contents <30820101> /Name (MARKERSIGNER)>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERSIGNER"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.Signatures));
    }
}
