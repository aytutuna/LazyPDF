using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EncryptionTests
{
    private static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    /// <summary>Objects 1 to 4 plain pages, an /Info in 5, the content in 6, an object stream in 7 and the /Encrypt dictionary in 8.</summary>
    private static (byte[] File, PdfSecurity Security) EncryptedFile(PdfCryptStrength strength, string user)
    {
        var security = PdfSecurity.Create(user, "owner", PdfPermissions.All, strength, FileId, new Random(7));
        string Hex(int number, string text) => "<" + Convert.ToHexString(security.EncryptString(number, 0, Encoding.Latin1.GetBytes(text))) + ">";
        var pdf = new TestPdf("%PDF-1.6\n");
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Lang " + Hex(1, "en-US") + ">>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 50 50]>>");
        pdf.Obj(5, "<</Title " + Hex(5, "Secret title") + ">>");
        pdf.Stream(6, "", security.EncryptStream(6, 0, TestPdf.Latin("0 0 m"), new PdfDictionary()));
        // Strings inside an object stream are not encrypted themselves; the stream is.
        string packed = "9 0 <</Note (plain text)>>";
        pdf.Stream(7, "/Type /ObjStm /N 1 /First 4", security.EncryptStream(7, 0, TestPdf.Latin(packed), new PdfDictionary()));
        pdf.Obj(8, security.Dictionary.ToString());
        string id = Convert.ToHexString(FileId);
        return (pdf.Finish($"/Root 1 0 R /Info 5 0 R /Encrypt 8 0 R /ID [<{id}> <{id}>]"), security);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void StringsAndStreamsAreDecryptedAsObjectsLoad(PdfCryptStrength strength)
    {
        var (file, _) = EncryptedFile(strength, "");
        var document = PdfDocument.Open(file);
        Assert.True(document.IsEncrypted);
        Assert.NotNull(document.Security);
        Assert.Equal("Secret title", TestPdf.Text(((PdfString)document.Info!["Title"]!).Bytes));
        Assert.Equal("en-US", TestPdf.Text(((PdfString)document.Catalog["Lang"]!).Bytes));
        Assert.Equal("0 0 m", TestPdf.Text(document.Pages[0].Contents()));
    }

    [Fact]
    public void EncryptDictionaryIsNotDecrypted()
    {
        var (file, security) = EncryptedFile(PdfCryptStrength.Aes256, "");
        var document = PdfDocument.Open(file);
        var stored = (PdfDictionary)document.Get(8)!;
        Assert.Equal(((PdfString)security.Dictionary["U"]!).Bytes, ((PdfString)stored["U"]!).Bytes);
    }

    [Fact]
    public void PasswordIsAskedFor()
    {
        var (file, _) = EncryptedFile(PdfCryptStrength.Aes256, "open sesame");
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file)).Problem);
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file, "wrong")).Problem);
        var document = PdfDocument.Open(file, "open sesame");
        Assert.Equal("Secret title", TestPdf.Text(((PdfString)document.Info!["Title"]!).Bytes));
    }

    [Fact]
    public void EncryptedFileWithABrokenTableIsRebuiltAndStillDecrypts()
    {
        var (file, _) = EncryptedFile(PdfCryptStrength.Aes128, "");
        var document = PdfDocument.Open(TestPdf.Replace(file, "startxref", "startxxxxx"));
        Assert.True(document.XrefRebuilt);
        Assert.Equal("Secret title", TestPdf.Text(((PdfString)document.Info!["Title"]!).Bytes));
        Assert.Equal("0 0 m", TestPdf.Text(document.Pages[0].Contents()));
        var note = (PdfDictionary)document.Get(9)!;
        Assert.Equal("plain text", TestPdf.Text(((PdfString)note["Note"]!).Bytes));
    }
}
