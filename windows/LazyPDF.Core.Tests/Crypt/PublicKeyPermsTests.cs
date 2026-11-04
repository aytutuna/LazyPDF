using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyPermsTests
{
    private static readonly byte[] Id = SyntheticEncryption.Id;

    private static PdfDictionary Modern(PdfCryptStrength strength = PdfCryptStrength.Aes256) =>
        PdfSecurity.Create("user", "owner", PdfPermissions.Print | PdfPermissions.Copy, strength, Id).Dictionary.Copy();

    private static PdfSecurity Open(PdfDictionary dictionary) => PdfSecurity.Open(dictionary, Id, "user")!;

    [Fact]
    public void UntouchedR6IsFine()
    {
        Assert.False(Open(Modern()).PermsMismatch);
    }

    [Fact]
    public void ChangedPermissionsAreFlaggedAndTheFileStillOpens()
    {
        var dictionary = Modern();
        dictionary["P"] = new PdfNumber(-4);

        var security = Open(dictionary);

        Assert.True(security.PermsMismatch);
        Assert.Equal(PdfPermissions.All, security.Permissions);
    }

    [Fact]
    public void ChangedMetadataFlagIsFlagged()
    {
        var dictionary = Modern();
        dictionary["EncryptMetadata"] = new PdfBoolean(false);

        Assert.True(Open(dictionary).PermsMismatch);
    }

    [Fact]
    public void DamagedPermsIsFlagged()
    {
        var dictionary = Modern();
        byte[] perms = [.. ((PdfString)dictionary["Perms"]!).Bytes];
        perms[3] ^= 0x10;
        dictionary["Perms"] = new PdfString(perms, true);

        Assert.True(Open(dictionary).PermsMismatch);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(8)]
    public void ShortOrMissingPermsIsFlagged(int length)
    {
        var dictionary = Modern();
        if (length == 0) dictionary.Remove("Perms");
        else dictionary["Perms"] = new PdfString(new byte[length], true);

        Assert.True(Open(dictionary).PermsMismatch);
    }

    [Fact]
    public void PermsOfAnotherFileKeyIsFlagged()
    {
        var dictionary = Modern();
        dictionary["Perms"] = Modern()["Perms"];

        Assert.True(Open(dictionary).PermsMismatch);
    }

    [Fact]
    public void OwnerOpenChecksToo()
    {
        var dictionary = Modern();
        dictionary["P"] = new PdfNumber(-4);

        Assert.True(PdfSecurity.Open(dictionary, Id, "owner")!.PermsMismatch);
    }

    [Fact]
    public void OlderRevisionsAreNotChecked()
    {
        Assert.False(PdfSecurity.Open(SyntheticEncryption.Modern(5, "u", "o").Dictionary, Id, "u")!.PermsMismatch);
        Assert.False(PdfSecurity.Open(Modern(PdfCryptStrength.Aes128), Id, "user")!.PermsMismatch);
    }

    [Fact]
    public void R6WithNoPermsAtAllIsFlagged()
    {
        Assert.True(PdfSecurity.Open(SyntheticEncryption.Modern(6, "u", "o").Dictionary, Id, "u")!.PermsMismatch);
    }

    [Fact]
    public void FixtureFromAnotherWriterIsFine()
    {
        var fixture = EncryptedFixture.Load("crypt-aes256.pdf");

        Assert.False(PdfSecurity.Open(fixture.Encrypt, fixture.Id, "secret")!.PermsMismatch);
    }

    [Fact]
    public void DocumentExposesTheFact()
    {
        byte[] file = PdfDocument.Open(PublicKeyFiles.Plain()).SaveRewrite(new PdfSaveOptions(
            Security: PdfSecurity.Create("", "o", PdfPermissions.Print, PdfCryptStrength.Aes256, Id), DocumentId: Id));
        using var untouched = PdfDocument.Open(file);

        // Same length, so the offsets stay right: the last digit of /P is the only change.
        string text = Encoding.Latin1.GetString(file);
        var p = Regex.Match(text, @"/P -(\d+)");
        char last = p.Value[^1];
        byte[] edited = Encoding.Latin1.GetBytes(text[..(p.Index + p.Length - 1)] + (char)(last == '9' ? '8' : last + 1) + text[(p.Index + p.Length)..]);
        using var tampered = PdfDocument.Open(edited);

        Assert.False(untouched.Security!.PermsMismatch);
        Assert.True(tampered.Security!.PermsMismatch);
        Assert.Empty(tampered.Repairs);
    }
}
