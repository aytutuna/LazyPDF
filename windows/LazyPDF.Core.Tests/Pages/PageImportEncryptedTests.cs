using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImportEncryptedTests
{
    private static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    private static PdfSecurity Secure(PdfCryptStrength strength) =>
        PdfSecurity.Create("", "owner", PdfPermissions.All, strength, FileId, new Random(7));

    private static byte[] Encrypt(byte[] plain, PdfCryptStrength strength) =>
        PdfDocument.Open(plain).SaveRewrite(new PdfSaveOptions(false, Secure(strength), FileId));

    private static bool Shows(byte[] file, string text) => Encoding.Latin1.GetString(file).Contains(text);

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void PagesOfAnEncryptedSourceComeAcrossReadable(PdfCryptStrength strength)
    {
        var source = PdfDocument.Open(Encrypt(PageImportTests.Source(), strength));
        Assert.True(source.IsEncrypted);
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, source, [0, 1], 1);
        Assert.Equal([1, 11, 12], PageTestFiles.Order(target));
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.False(again.IsEncrypted);
        var image = again.ObjectNumbers.Select(again.Get).OfType<PdfStream>().Single(s => again.Name(s.Dictionary, "Subtype") == "Image");
        Assert.Equal([(byte)0x80], again.Data(image));
        Assert.Equal(["Page 1", "Page 11", "Page 12"], PageTestFiles.Reopen(target));
    }

    [Fact]
    public void FormValuesOfAnEncryptedSourceComeAcrossAsText()
    {
        var plain = FormSource();
        var source = PdfDocument.Open(Encrypt(plain, PdfCryptStrength.Aes256));
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, source, [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var field = (PdfDictionary)again.Resolve(again.Array(again.Dict(again.Catalog, "AcroForm"), "Fields")!.Items[0])!;
        Assert.Equal("Alice", Encoding.Latin1.GetString(((PdfString)field["V"]!).Bytes));
    }

    private static byte[] FormSource() => PageImportTests.Source("/Annots [50 0 R]",
        "/AcroForm <</Fields [50 0 R]>>",
        pdf => pdf.Obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /Rect [0 0 50 20]>>"));

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void PagesGoIntoAnEncryptedTargetAndAreEncryptedWithIt(PdfCryptStrength strength)
    {
        var target = PdfDocument.Open(Encrypt(PageTestFiles.Make(1), strength));
        PageOperations.ImportPages(target, PdfDocument.Open(PageImportTests.Source()), [0], 1);
        byte[] saved = target.SaveRewrite(new PdfSaveOptions(true, target.Security));
        Assert.False(Shows(saved, "Page 11"));
        var again = PdfDocument.Open(saved);
        Assert.True(again.IsEncrypted);
        Assert.Equal([1, 11], PageTestFiles.Order(again));
    }

    [Fact]
    public void AnEncryptedFileTakesPagesInASession()
    {
        var session = PdfEditSession.Open(Encrypt(PageTestFiles.Make(2), PdfCryptStrength.Aes256));
        var source = PdfDocument.Open(Encrypt(PageImportTests.Source(), PdfCryptStrength.Aes128));
        PageOperations.ImportPages(session.Document, source, [0, 2], 1);
        Assert.True(session.Commit("Insert pages"));
        Assert.False(Shows(session.Current.ToArray(), "Page 11"));
        var reopened = PdfDocument.Open(session.Current.ToArray());
        Assert.Equal([1, 11, 13, 2], PageTestFiles.Order(reopened));
        Assert.True(session.Undo());
        Assert.Equal([1, 2], PageTestFiles.Order(session.Document));
    }

    [Fact]
    public void ADeleteAndAMoveInAnEncryptedFileReadBack()
    {
        var session = PdfEditSession.Open(Encrypt(PageTestFiles.Make(4), PdfCryptStrength.Aes256));
        PageOperations.Delete(session.Document, [0]);
        PageOperations.Move(session.Document, [0], 3);
        Assert.True(session.Commit("Edit"));
        Assert.Equal([3, 4, 2], PageTestFiles.Order(PdfDocument.Open(session.Current.ToArray())));
    }
}
