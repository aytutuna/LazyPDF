using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Comments and hidden-layer annotations that a structure tree still points at, and encryption.
public class SanitizeStructureTests
{
    private static byte[] Tagged(string annotExtra = "", string catalogExtra = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /StructTreeRoot 7 0 R {catalogExtra}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [5 0 R] /StructParents 1>>");
        pdf.Stream(4, "", "0 g 10 10 20 20 re f");
        pdf.Obj(5, $"<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /T (MARKERWHO) /Contents (MARKERNOTE) /StructParent 0 {annotExtra}>>");
        pdf.Obj(7, "<</Type /StructTreeRoot /K 8 0 R /ParentTree 9 0 R>>");
        pdf.Obj(8, "<</Type /StructElem /S /Annot /P 7 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 5 0 R /Pg 3 0 R>>>>");
        pdf.Obj(9, "<</Nums [0 8 0 R]>>");
        pdf.Obj(10, "<</Type /OCG /Name (Off)>>");
        return pdf.Finish();
    }

    [Fact]
    public void ACommentThatTheStructureTreeReachesIsGone()
    {
        byte[] file = Tagged();
        Assert.True(OptimizeKit.Everywhere(file, "MARKERNOTE"));
        using var document = PdfDocument.Open(file);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERNOTE"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERWHO"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.Comments));
        Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
    }

    [Fact]
    public void ThePlaceOfARemovedCommentInTheStructureTreeIsGoneToo()
    {
        using var document = PdfDocument.Open(Tagged());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "OBJR"));
    }

    [Fact]
    public void AnAnnotationOfAHiddenLayerThatTheStructureTreeReachesIsGone()
    {
        byte[] file = Tagged("/OC 10 0 R", "/OCProperties <</OCGs [10 0 R] /D <</OFF [10 0 R]>>>>");
        using var document = PdfDocument.Open(file);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { Comments = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERNOTE"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.HiddenLayers));
    }

    private static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    private static byte[] Encrypted(PdfPermissions permissions)
    {
        var security = PdfSecurity.Create("user", "owner", permissions, PdfCryptStrength.Aes256, FileId, new Random(3));
        return PdfDocument.Open(TestPdf.Simple(2)).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: FileId));
    }

    [Fact]
    public void AnEncryptedFileKeepsItsEncryptionByDefault()
    {
        using var document = PdfDocument.Open(Encrypted(PdfPermissions.All), "user");
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(result.Bytes)).Problem);
        using var again = PdfDocument.Open(result.Bytes, "user");
        Assert.True(again.IsEncrypted);
        Assert.Equal(2, again.Pages.Count);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void AGivenIdDoesNotBreakTheKeptHandler(PdfCryptStrength strength)
    {
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, FileId, new Random(3));
        byte[] file = PdfDocument.Open(TestPdf.Simple(2)).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: FileId));
        using var document = PdfDocument.Open(file, "user");
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { DocumentId = Enumerable.Range(40, 16).Select(i => (byte)i).ToArray() });
        using var again = PdfDocument.Open(result.Bytes, "user");
        Assert.Equal(2, again.Pages.Count);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void AHandlerPassedInTheOptionsKeepsTheFileOpenable(PdfCryptStrength strength)
    {
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, FileId, new Random(3));
        byte[] file = PdfDocument.Open(TestPdf.Simple(2)).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: FileId));
        using var document = PdfDocument.Open(file, "user");
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { Security = document.Security });
        using var again = PdfDocument.Open(result.Bytes, "user");
        Assert.Equal(2, again.Pages.Count);
    }

    [Fact]
    public void EncryptionCanBeDroppedOnRequest()
    {
        using var document = PdfDocument.Open(Encrypted(PdfPermissions.All), "user");
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { KeepEncryption = false });
        using var again = PdfDocument.Open(result.Bytes);
        Assert.False(again.IsEncrypted);
    }
}
