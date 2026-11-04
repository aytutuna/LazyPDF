using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyRoundTripTests
{
    [Theory]
    [InlineData(PdfCryptStrength.Aes256, false)]
    [InlineData(PdfCryptStrength.Aes256, true)]
    [InlineData(PdfCryptStrength.Aes128, false)]
    [InlineData(PdfCryptStrength.Aes128, true)]
    public void RecipientReadsWhatWasSealed(PdfCryptStrength strength, bool objectStreams)
    {
        var file = PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice)], strength, objectStreams);

        Assert.DoesNotContain(PublicKeyFiles.PageText, Encoding.Latin1.GetString(file));
        using var document = PdfDocument.Open(file, PublicKeyFiles.Alice);
        Assert.True(document.IsEncrypted);
        Assert.True(document.Security!.IsPublicKey);
        Assert.Equal(strength == PdfCryptStrength.Aes256 ? 6 : 4, document.Security.Revision);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
        Assert.Equal("Sealed title", Encoding.Latin1.GetString(((PdfString)document.Info!["Title"]!).Bytes));
        Assert.Empty(document.Repairs);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256, "adbe.pkcs7.s5", 5, "AESV3")]
    [InlineData(PdfCryptStrength.Aes128, "adbe.pkcs7.s5", 4, "AESV2")]
    public void DictionaryHasTheShapeOfTheSpec(PdfCryptStrength strength, string subFilter, int v, string method)
    {
        var dictionary = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], strength).Dictionary;

        Assert.Equal("Adobe.PubSec", ((PdfName)dictionary["Filter"]!).Value);
        Assert.Equal(subFilter, ((PdfName)dictionary["SubFilter"]!).Value);
        Assert.Equal(v, (int)((PdfNumber)dictionary["V"]!).Value);
        var filter = (PdfDictionary)((PdfDictionary)dictionary["CF"]!)[((PdfName)dictionary["StmF"]!).Value]!;
        Assert.Equal(method, ((PdfName)filter["CFM"]!).Value);
        var recipient = ((PdfString)((PdfArray)filter["Recipients"]!).Items.Single()).Bytes;
        Assert.Equal(0x30, recipient[0]);
    }

    [Fact]
    public void FileRecordsTheHandlerInItsHeaderAndTrailer()
    {
        string text = Encoding.Latin1.GetString(PublicKeyFiles.Seal(PublicKeyFiles.Alice));

        Assert.StartsWith("%PDF-1.7", text);
        Assert.Contains("/Adobe.PubSec", text);
        Assert.Contains("/Encrypt ", text);
        Assert.StartsWith("%PDF-1.6", Encoding.Latin1.GetString(PublicKeyFiles.Seal(PublicKeyFiles.Alice, PdfCryptStrength.Aes128)));
    }

    [Fact]
    public void EachRecipientOpensTheSameFileWithTheirOwnPermissions()
    {
        var file = PublicKeyFiles.Seal([
            new PdfRecipient(PublicKeyFiles.Alice, PdfPermissions.Print | PdfPermissions.Copy),
            new PdfRecipient(PublicKeyFiles.Bob, PdfPermissions.All, CanChangeEncryption: true),
        ]);

        using var alice = PdfDocument.Open(file, PublicKeyFiles.Alice);
        using var bob = PdfDocument.Open(file, PublicKeyFiles.Bob);

        Assert.Equal(PdfPermissions.Print | PdfPermissions.Copy, alice.Security!.Permissions);
        Assert.False(alice.Security.OpenedAsOwner);
        Assert.Equal(PdfPermissions.All, bob.Security!.Permissions);
        Assert.True(bob.Security.OpenedAsOwner);
        Assert.Equal(PublicKeyFiles.Content(alice), PublicKeyFiles.Content(bob));
    }

    [Fact]
    public void DefaultRecipientHasAllPermissionsButNoOwnership()
    {
        using var document = PdfDocument.Open(PublicKeyFiles.Seal(PublicKeyFiles.Alice), PublicKeyFiles.Alice);

        Assert.Equal(PdfPermissions.All, document.Security!.Permissions);
        Assert.False(document.Security.OpenedAsOwner);
    }

    [Fact]
    public void NewHandlerIsAnOwner()
    {
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice, PdfPermissions.Print)], PdfCryptStrength.Aes256);

        Assert.True(created.OpenedAsOwner);
        Assert.True(created.IsPublicKey);
        Assert.False(created.PermsMismatch);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void ReaderDecryptsWhatTheCreatorEncrypted(PdfCryptStrength strength)
    {
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], strength);
        var reader = PdfSecurity.OpenPublicKey(created.Dictionary, PublicKeyFiles.Alice)!;
        byte[] plain = "BT (text) Tj ET"u8.ToArray();

        Assert.Equal(plain, reader.DecryptStream(7, 0, created.EncryptStream(7, 0, plain, new PdfDictionary()), new PdfDictionary()));
        Assert.Equal(plain, reader.DecryptString(8, 0, created.EncryptString(8, 0, plain)));
    }

    [Fact]
    public void TwoSealsOfTheSameFileDiffer()
    {
        Assert.NotEqual(PublicKeyFiles.Seal(PublicKeyFiles.Alice), PublicKeyFiles.Seal(PublicKeyFiles.Alice));
    }

    [Fact]
    public void RecipientCountIsBounded()
    {
        Assert.Throws<ArgumentException>(() => PdfSecurity.CreatePublicKey([], PdfCryptStrength.Aes256));
    }

    [Fact]
    public void PathOverloadOpensTheFile()
    {
        string path = Path.Combine(Path.GetTempPath(), $"pubkey-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, PublicKeyFiles.Seal(PublicKeyFiles.Alice));
        try
        {
            using var document = PdfDocument.Open(path, PublicKeyFiles.Alice);
            Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void IncrementalUpdateOfSealedFileOpensAgain()
    {
        using var document = PdfDocument.Open(PublicKeyFiles.Seal(PublicKeyFiles.Alice), PublicKeyFiles.Alice);
        document.Info!["Title"] = new PdfString("Changed"u8.ToArray(), false);

        using var again = PdfDocument.Open(document.SaveIncremental(), PublicKeyFiles.Alice);

        Assert.Equal("Changed", Encoding.Latin1.GetString(((PdfString)again.Info!["Title"]!).Bytes));
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(again));
    }
}
