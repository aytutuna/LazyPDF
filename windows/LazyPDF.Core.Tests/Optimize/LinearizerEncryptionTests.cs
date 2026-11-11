using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LinearizerEncryptionTests
{
    private static byte[] Encrypted(PdfCryptStrength strength, string user = "")
    {
        var security = LinearizerKit.Secure(strength, user);
        return PdfDocument.Open(LinearizerKit.Make(5)).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: LinearizerKit.FileId));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void AnEncryptedFileStaysEncryptedUnderItsOwnHandler(PdfCryptStrength strength)
    {
        using var source = PdfDocument.Open(Encrypted(strength));
        byte[] file = LinearizerKit.Keep($"encrypted-{strength}", source.SaveLinearized(new PdfSaveOptions(Security: source.Security)));

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.True(again.IsEncrypted);
        Assert.Equal(source.Pages.Select(p => p.Contents().Length), again.Pages.Select(p => p.Contents().Length));
        Assert.Equal(LinearizerKit.PigText(source), LinearizerKit.PigText(file));
        Assert.Equal(source.Id[0], again.Id[0]);
    }

    [Fact]
    public void WithoutAHandlerTheOutputIsOpen()
    {
        using var source = PdfDocument.Open(Encrypted(PdfCryptStrength.Aes256));
        byte[] file = source.SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.False(again.IsEncrypted);
        Assert.Equal(source.Pages[3].Contents(), again.Pages[3].Contents());
    }

    [Fact]
    public void ANewHandlerLocksAnOpenFileWithItsPassword()
    {
        var security = LinearizerKit.Secure(PdfCryptStrength.Aes256, "user");
        byte[] file = PdfDocument.Open(LinearizerKit.Make(4)).SaveLinearized(new PdfSaveOptions(Security: security));

        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file)).Problem);
        LinearizerKit.Verify(file, "user");
        using var again = PdfDocument.Open(file, "user");
        Assert.Equal(4, again.Pages.Count);
    }

    [Fact]
    public void TheEncryptionDictionaryStaysInTheFirstSection()
    {
        using var source = PdfDocument.Open(Encrypted(PdfCryptStrength.Aes256));
        byte[] file = source.SaveLinearized(new PdfSaveOptions(Security: source.Security));
        var parameters = LinearizerKit.Verify(file);

        string text = System.Text.Encoding.Latin1.GetString(file);
        int at = text.IndexOf("/Encrypt ", StringComparison.Ordinal);
        Assert.InRange(at, 1, (int)parameters["H0"]);
        Assert.Contains("/Filter/Standard", text.Replace(" ", ""));
    }

    [Fact]
    public void ARestrictedFileNeedsTheOwnerToLoseItsEncryption()
    {
        var security = PdfSecurity.Create("", "owner", PdfPermissions.Print, PdfCryptStrength.Aes256, LinearizerKit.FileId, new Random(1));
        byte[] locked = PdfDocument.Open(LinearizerKit.Make(2)).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: LinearizerKit.FileId));

        using var asUser = PdfDocument.Open(locked);
        Assert.Throws<PdfPermissionException>(() => asUser.SaveLinearized());
        LinearizerKit.Verify(asUser.SaveLinearized(new PdfSaveOptions(Security: asUser.Security)));
        using var asOwner = PdfDocument.Open(locked, "owner");
        LinearizerKit.Verify(asOwner.SaveLinearized());
    }

    private static byte[] WithGlobals()
    {
        var security = LinearizerKit.Secure(PdfCryptStrength.Aes128);
        var pdf = new TestPdf("%PDF-1.6\n");
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Extra 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 50 50]>>");
        pdf.Stream(6, "/Filter [/Crypt /JBIG2Decode] /DecodeParms [<</Name /Identity>> <</JBIG2Globals 9 0 R>>]", TestPdf.Latin("HELLO"));
        pdf.Stream(9, "", security.EncryptStream(9, 0, TestPdf.Latin("globals"), new PdfDictionary()));
        pdf.Obj(8, security.Dictionary.ToString());
        string id = Convert.ToHexString(LinearizerKit.FileId);
        return pdf.Finish($"/Root 1 0 R /Encrypt 8 0 R /ID [<{id}> <{id}>]");
    }

    [Theory]
    [InlineData("")]
    [InlineData("other")]
    public void AStreamWithACryptStageKeepsItsParameterReferencesUnderANewHandler(string user)
    {
        using var source = PdfDocument.Open(WithGlobals());
        var options = user == "" ? new PdfSaveOptions() : new PdfSaveOptions(Security: LinearizerKit.Secure(PdfCryptStrength.Aes256, user));
        byte[] file = source.SaveLinearized(options);

        LinearizerKit.Verify(file, user == "" ? null : user);
        using var again = PdfDocument.Open(file, user == "" ? null : user);
        var extra = again.Resolve<PdfStream>(again.Catalog["Extra"])!;
        Assert.Equal("JBIG2Decode", ((PdfName)Assert.Single(((PdfArray)again.Resolve(extra.Dictionary["Filter"])!).Items)).Value);
        var parameters = (PdfDictionary)again.Resolve(Assert.Single(((PdfArray)again.Resolve(extra.Dictionary["DecodeParms"])!).Items))!;
        Assert.Equal("globals", TestPdf.Text(again.RawData(again.Resolve<PdfStream>(parameters["JBIG2Globals"])!)));
    }
}
