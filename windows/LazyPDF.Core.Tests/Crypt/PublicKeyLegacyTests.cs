using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyLegacyTests
{
    private static readonly byte[] Text = "secret"u8.ToArray();

    [Fact]
    public void S4WithVersionFourKeepsItsRecipientsInTheFilter()
    {
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes128);
        var dictionary = created.Dictionary.Copy();
        dictionary["SubFilter"] = new PdfName("adbe.pkcs7.s4");

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice)!;

        Assert.Equal(Text, reader.DecryptString(4, 0, created.EncryptString(4, 0, Text)));
    }

    [Fact]
    public void VersionOneIsFortyBitWhateverLengthSaysAndIsRead()
    {
        var (dictionary, cipher) = Rc4File("adbe.pkcs7.s3", 1, 128);

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice)!;

        Assert.Equal(Text, reader.DecryptString(4, 0, cipher));
    }

    [Fact]
    public void AStrayEncryptMetadataIsIgnoredBeforeVersionFour()
    {
        var (dictionary, cipher) = Rc4File("adbe.pkcs7.s4", 2, 40);
        dictionary.Add("EncryptMetadata", new PdfBoolean(false));

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice)!;

        Assert.Equal(Text, reader.DecryptString(4, 0, cipher));
        Assert.True(reader.EncryptMetadata);
    }

    [Theory]
    [InlineData("StmF")]
    [InlineData("StrF")]
    [InlineData("EFF")]
    public void TheFilterWithTheRecipientsMayBeNamedByAnyOfTheThreeEntries(string key)
    {
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes128);
        var dictionary = created.Dictionary.Copy();
        foreach (string other in new[] { "StmF", "StrF", "EFF" }) dictionary[other] = new PdfName("Identity");
        dictionary[key] = new PdfName("DefaultCryptFilter");

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice);

        Assert.NotNull(reader);
    }

    [Fact]
    public void NoEntryNamingAFilterWithRecipientsIsDamaged()
    {
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes128);
        var dictionary = created.Dictionary.Copy();
        dictionary["StmF"] = new PdfName("Identity");
        dictionary["StrF"] = new PdfName("Identity");

        var problem = Assert.Throws<PdfReadException>(() => PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice));

        Assert.Equal(PdfReadProblem.Damaged, problem.Problem);
    }

    // A file with 40-bit RC4 and one recipient, and the string "secret" of object 4 encrypted for it as the format has it.
    private static (PdfDictionary Dictionary, byte[] Cipher) Rc4File(string subFilter, int version, int length)
    {
        var sealedAes = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes128);
        var filter = (PdfDictionary)((PdfDictionary)sealedAes.Dictionary["CF"]!)["DefaultCryptFilter"]!;
        var stored = (PdfArray)filter["Recipients"]!;
        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Adobe.PubSec"));
        dictionary.Add("SubFilter", new PdfName(subFilter));
        dictionary.Add("V", new PdfNumber(version));
        dictionary.Add("Length", new PdfNumber(length));
        dictionary.Add("Recipients", stored);

        var cms = new EnvelopedCms();
        cms.Decode(((PdfString)stored.Items[0]).Bytes);
        cms.Decrypt(new System.Security.Cryptography.X509Certificates.X509Certificate2Collection(PublicKeyFiles.Alice));
        var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        hash.AppendData(cms.ContentInfo.Content.AsSpan(0, 20));
        hash.AppendData(((PdfString)stored.Items[0]).Bytes);
        byte[] fileKey = hash.GetHashAndReset()[..5];
        byte[] input = [.. fileKey, 4, 0, 0, 0, 0];
        return (dictionary, Rc4.Apply(MD5.HashData(input)[..10], Text));
    }
}
