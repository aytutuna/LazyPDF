using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StreamRulesTests
{
    private static readonly byte[] Plain = "stream bytes, long enough to span blocks"u8.ToArray();

    private static PdfDictionary Parse(string text) =>
        (PdfDictionary)new PdfLexer(new PdfArrayBytes(Encoding.ASCII.GetBytes(text))).ReadObject();

    private static (PdfSecurity Security, BuiltEncryption Built) Open(bool encryptMetadata = true)
    {
        var built = SyntheticEncryption.Legacy(4, 4, 128, "u", "o", cfm: "AESV2", encryptMetadata: encryptMetadata);
        return (PdfSecurity.Open(built.Dictionary, SyntheticEncryption.Id, "u")!, built);
    }

    [Fact]
    public void XRefStreamsAreNeverEncrypted()
    {
        var (security, _) = Open();
        var dictionary = Parse("<</Type /XRef /Size 3>>");

        Assert.Same(Plain, security.EncryptStream(5, 0, Plain, dictionary));
        Assert.Same(Plain, security.DecryptStream(5, 0, Plain, dictionary));
    }

    [Fact]
    public void MetadataIsClearOnlyWhenEncryptMetadataIsFalse()
    {
        var metadata = Parse("<</Type /Metadata /Subtype /XML>>");
        var (clear, _) = Open(encryptMetadata: false);
        var (encrypted, _) = Open();

        Assert.Same(Plain, clear.DecryptStream(5, 0, Plain, metadata));
        Assert.Same(Plain, clear.EncryptStream(5, 0, Plain, metadata));
        Assert.NotEqual(Plain, encrypted.EncryptStream(5, 0, Plain, metadata));
    }

    [Fact]
    public void CryptFilterNamingIdentityLeavesTheStreamAlone()
    {
        var (security, _) = Open();

        Assert.Same(Plain, security.DecryptStream(5, 0, Plain, Parse("<</Filter /Crypt /DecodeParms <</Name /Identity>>>>")));
        Assert.Same(Plain, security.DecryptStream(5, 0, Plain, Parse("<</Filter /Crypt>>")));
        Assert.Same(Plain, security.DecryptStream(5, 0, Plain, Parse("<</Filter [/Crypt /FlateDecode] /DecodeParms [<</Name /Identity>> null]>>")));
    }

    [Fact]
    public void CryptFilterNamingAnotherFilterUsesIt()
    {
        var built = SyntheticEncryption.Legacy(4, 4, 128, "u", "o", cfm: "AESV2");
        var security = PdfSecurity.Open(built.Dictionary, SyntheticEncryption.Id, "u")!;
        byte[] stored = SyntheticEncryption.StoreRc4(built.FileKey, 7, 0, Plain);

        var decrypted = security.DecryptStream(7, 0, stored, Parse("<</Filter /Crypt /DecodeParms <</Name /Rc4CF>>>>"));

        Assert.Equal(Plain, decrypted);
    }

    [Fact]
    public void FiltersWithoutCryptDecryptWithTheStreamFilter()
    {
        var (security, built) = Open();
        byte[] stored = SyntheticEncryption.StoreAes128(built.FileKey, 7, 0, Plain);

        Assert.Equal(Plain, security.DecryptStream(7, 0, stored, Parse("<</Filter /FlateDecode>>")));
        Assert.Equal(Plain, security.DecryptStream(7, 0, stored, Parse("<</Filter [/ASCII85Decode /FlateDecode]>>")));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(5)]
    [InlineData(16)]
    [InlineData(17)]
    [InlineData(31)]
    public void AesDataTooShortForABlockIsEmpty(int length)
    {
        var (security, _) = Open();

        Assert.Empty(security.DecryptString(1, 0, new byte[length]));
    }

    [Fact]
    public void AesTrailingPartialBlockIsDropped()
    {
        var (security, built) = Open();
        byte[] stored = [.. SyntheticEncryption.StoreAes128(built.FileKey, 1, 0, Plain), 1, 2, 3];

        Assert.Equal(Plain, security.DecryptString(1, 0, stored));
    }

    [Fact]
    public void AesBadPaddingTailKeepsTheDecryptedBlocks()
    {
        var (security, built) = Open();
        byte[] stored = SyntheticEncryption.StoreAes128(built.FileKey, 1, 0, Plain);
        // Another cipher text block in front of the last one makes the final plain block garbage.
        stored[^17] ^= 0x55;

        byte[] plain = security.DecryptString(1, 0, stored);

        Assert.Equal(stored.Length - 16, plain.Length);
        Assert.Equal(Plain[..16], plain[..16]);
    }

    [Fact]
    public void AesGarbageDoesNotThrow()
    {
        var (security, _) = Open();
        byte[] garbage = new byte[64];
        new Random(3).NextBytes(garbage);

        Assert.True(security.DecryptStream(1, 0, garbage, new PdfDictionary()).Length <= 48);
    }

    [Fact]
    public void Rc4OfEmptyDataIsEmpty()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "u", "o");
        var security = PdfSecurity.Open(built.Dictionary, SyntheticEncryption.Id, "u")!;

        Assert.Empty(security.DecryptString(1, 0, []));
        Assert.Empty(security.EncryptString(1, 0, []));
    }
}
