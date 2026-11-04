using System.IO.Compression;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The check reports what it could not look into, and looks into what a viewer of the attachment would read.
public class RedactOpaqueFileTests
{
    private static RedactionResult RedactWithAttachment(byte[] attachment, string catalogExtra = "/Names <</EmbeddedFiles <</Names [(a.bin) 8 0 R]>>>>")
    {
        using var document = RedactionFiles.Open(RedactionFiles.Word, more: pdf =>
        {
            pdf.Obj(8, "<</Type /Filespec /F (a.bin) /EF <</F 9 0 R>>>>");
            pdf.Stream(9, "/Type /EmbeddedFile", attachment);
        }, catalogExtra: catalogExtra);
        return new PdfRedactor(document).Apply([RedactionMark.FromRect(0, RedactionFiles.Over)]);
    }

    [Fact]
    public void PicturesInAnImageCodecAreNotAnUnreadStream()
    {
        using var document = RedactionFiles.Open(RedactionFiles.Word + " q 20 0 0 20 400 600 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0xFF, 0xD9]));
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, RedactionFiles.Over));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void AttachedSourceThatIsCodedByItsFontIsRead()
    {
        var nested = new TestPdf();
        nested.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        nested.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        nested.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        nested.Stream(4, "", "BT /F1 12 Tf 100 100 Td <0102030405060708> Tj ET");
        nested.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [1 /Z /Q /X /C /Y /C /L /E]>>>>");
        using var document = RedactionFiles.Open("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET", more: pdf =>
        {
            pdf.Obj(8, "<</Type /Filespec /F (a.pdf) /EF <</F 9 0 R>>>>");
            pdf.Stream(9, "/Type /EmbeddedFile", nested.Finish());
        }, catalogExtra: "/Names <</EmbeddedFiles <</Names [(a.pdf) 8 0 R]>>>>");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, RedactionFiles.Over)]);
        Assert.False(result.Verification.IsClean);
    }

    [Fact]
    public void AttachmentInAFormatThatIsNotOpenedIsNotChecked()
    {
        var result = RedactWithAttachment([0x28, 0xB5, 0x2F, 0xFD, 1, 2, 3, 4, 5, 6, 7, 8]);
        Assert.False(result.Verification.IsClean);
    }

    [Fact]
    public void AttachmentThatLooksCompressedIsNotChecked()
    {
        var bytes = new byte[4096];
        new Random(7).NextBytes(bytes);
        Assert.False(RedactWithAttachment(bytes).Verification.IsClean);
    }

    [Fact]
    public void PlainTextAttachmentIsChecked()
    {
        Assert.True(RedactWithAttachment(Encoding.ASCII.GetBytes("hello there")).Verification.IsClean);
    }

    [Fact]
    public void GzipUnderAPrivateKeyIsOpened()
    {
        var packed = new MemoryStream();
        using (var gzip = new GZipStream(packed, CompressionMode.Compress, true)) gzip.Write(Encoding.ASCII.GetBytes("ZQXSECRET ZQXSECRET"));
        using var document = RedactionFiles.Open(RedactionFiles.Word, more: pdf => pdf.Stream(9, "", packed.ToArray()), catalogExtra: "/Backup 9 0 R");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, RedactionFiles.Over)]);
        Assert.False(result.Verification.IsClean);
    }
}
