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
        var sealedAes = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes128);
        var filter = (PdfDictionary)((PdfDictionary)sealedAes.Dictionary["CF"]!)["DefaultCryptFilter"]!;
        var stored = (PdfArray)filter["Recipients"]!;
        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Adobe.PubSec"));
        dictionary.Add("SubFilter", new PdfName("adbe.pkcs7.s3"));
        dictionary.Add("V", new PdfNumber(1));
        dictionary.Add("Length", new PdfNumber(128));
        dictionary.Add("Recipients", stored);

        var cms = new EnvelopedCms();
        cms.Decode(((PdfString)stored.Items[0]).Bytes);
        cms.Decrypt(new System.Security.Cryptography.X509Certificates.X509Certificate2Collection(PublicKeyFiles.Alice));
        var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        hash.AppendData(cms.ContentInfo.Content.AsSpan(0, 20));
        hash.AppendData(((PdfString)stored.Items[0]).Bytes);
        byte[] fileKey = hash.GetHashAndReset()[..5];
        byte[] input = [.. fileKey, 4, 0, 0, 0, 0];
        byte[] cipher = Rc4.Apply(MD5.HashData(input)[..10], Text);

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice)!;

        Assert.Equal(Text, reader.DecryptString(4, 0, cipher));
    }
}
