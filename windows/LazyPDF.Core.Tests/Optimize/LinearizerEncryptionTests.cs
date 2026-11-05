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
}
