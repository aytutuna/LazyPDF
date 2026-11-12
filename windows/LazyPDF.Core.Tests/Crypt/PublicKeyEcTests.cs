using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyEcTests
{
    private static readonly Lazy<X509Certificate2> P256 = new(() => PublicKeyFiles.EcCertificate("Curve256", ECCurve.NamedCurves.nistP256));
    private static readonly Lazy<X509Certificate2> P384 = new(() => PublicKeyFiles.EcCertificate("Curve384", ECCurve.NamedCurves.nistP384));

    [Theory]
    [InlineData(PdfCryptStrength.Aes256, false)]
    [InlineData(PdfCryptStrength.Aes256, true)]
    [InlineData(PdfCryptStrength.Aes128, false)]
    public void P256RecipientReadsWhatWasSealed(PdfCryptStrength strength, bool objectStreams)
    {
        var file = PublicKeyFiles.Seal([new PdfRecipient(P256.Value)], strength, objectStreams);

        using var document = PdfDocument.Open(file, P256.Value);
        Assert.True(document.Security!.IsPublicKey);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
    }

    [Fact]
    public void P384RecipientReadsWhatWasSealed()
    {
        var file = PublicKeyFiles.Seal(P384.Value);

        using var document = PdfDocument.Open(file, P384.Value);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
    }

    [Fact]
    public void RsaAndEcRecipientsOpenTheSameFileWithTheirOwnPermissions()
    {
        var file = PublicKeyFiles.Seal([
            new PdfRecipient(PublicKeyFiles.Alice, PdfPermissions.Print),
            new PdfRecipient(P256.Value, PdfPermissions.All, CanChangeEncryption: true),
            new PdfRecipient(P384.Value, PdfPermissions.Copy),
        ]);

        using var rsa = PdfDocument.Open(file, PublicKeyFiles.Alice);
        using var p256 = PdfDocument.Open(file, P256.Value);
        using var p384 = PdfDocument.Open(file, P384.Value);

        Assert.Equal(PdfPermissions.Print, rsa.Security!.Permissions);
        Assert.Equal(PdfPermissions.All, p256.Security!.Permissions);
        Assert.True(p256.Security.OpenedAsOwner);
        Assert.Equal(PdfPermissions.Copy, p384.Security!.Permissions);
        Assert.False(p384.Security.OpenedAsOwner);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(p384));
    }

    [Fact]
    public void OtherCertificatesAreNotRecipients()
    {
        var file = PublicKeyFiles.Seal(P256.Value);
        var other = PublicKeyFiles.EcCertificate("Other", ECCurve.NamedCurves.nistP256);

        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file, other)).Problem);
        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file, P384.Value)).Problem);
        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file, PublicKeyFiles.Alice)).Problem);
        Assert.Equal(PdfReadProblem.CertificateRequired,
                     Assert.Throws<PdfReadException>(() => PdfDocument.Open(file, PublicKeyFiles.PublicPart(P256.Value))).Problem);
    }

    [Fact]
    public void CanProtectNeedsAKnownCurveAndKeyAgreement()
    {
        Assert.True(PdfRecipient.CanProtect(P256.Value));
        Assert.True(PdfRecipient.CanProtect(P384.Value));
        Assert.False(PdfRecipient.CanProtect(PublicKeyFiles.EcCertificate("Signer", ECCurve.NamedCurves.nistP256, X509KeyUsageFlags.DigitalSignature)));
        Assert.False(PdfRecipient.CanProtect(PublicKeyFiles.EcCertificate("Big", ECCurve.NamedCurves.nistP521)));
        Assert.Throws<ArgumentException>(() => PdfSecurity.CreatePublicKey(
            [new PdfRecipient(PublicKeyFiles.EcCertificate("Signer", ECCurve.NamedCurves.nistP256, X509KeyUsageFlags.DigitalSignature))],
            PdfCryptStrength.Aes256));
    }

    [Fact]
    public void KeyWrapMatchesRfc3394()
    {
        byte[] kek = Convert.FromHexString("000102030405060708090A0B0C0D0E0F");
        byte[] key = Convert.FromHexString("00112233445566778899AABBCCDDEEFF");
        byte[] expected = Convert.FromHexString("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5");
        Assert.Equal(expected, PdfCmsAgreement.Wrap(kek, key));
        Assert.Equal(key, PdfCmsAgreement.Unwrap(kek, expected));

        byte[] kek256 = Convert.FromHexString("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
        byte[] key256 = Convert.FromHexString("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F");
        byte[] wrapped = Convert.FromHexString("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21");
        Assert.Equal(wrapped, PdfCmsAgreement.Wrap(kek256, key256));
        wrapped[3] ^= 1;
        Assert.Null(PdfCmsAgreement.Unwrap(kek256, wrapped));
    }

    private static readonly byte[] GoldenContent = Enumerable.Range(1, 24).Select(i => (byte)i).ToArray();

    [Theory]
    [InlineData("P256")]
    [InlineData("P384")]
    public void GoldenEnvelopeIsWrittenAndRead(string curveName)
    {
        var (cert, recipientKey, ephemeralKey, x, y, envelope) = curveName == "P256" ? EcGolden.P256 : EcGolden.P384;
        var curve = curveName == "P256" ? ECCurve.NamedCurves.nistP256 : ECCurve.NamedCurves.nistP384;
        using var publicPart = X509CertificateLoader.LoadCertificate(Convert.FromHexString(cert));
        using var ephemeral = ECDiffieHellman.Create(new ECParameters
        {
            Curve = curve,
            D = Convert.FromHexString(ephemeralKey),
            Q = new ECPoint { X = Convert.FromHexString(x), Y = Convert.FromHexString(y) },
        });

        byte[] written = PdfCmsAgreement.Seal(GoldenContent, publicPart, ephemeral,
                                              Enumerable.Range(100, 32).Select(i => (byte)i).ToArray(),
                                              Enumerable.Range(200, 16).Select(i => (byte)i).ToArray());

        Assert.Equal(Convert.FromHexString(envelope), written);
        using var recipient = ECDsa.Create(new ECParameters
        {
            Curve = curve,
            D = Convert.FromHexString(recipientKey),
            Q = new ECPoint
            {
                X = publicPart.PublicKey.EncodedKeyValue.RawData[1..(1 + (curveName == "P256" ? 32 : 48))],
                Y = publicPart.PublicKey.EncodedKeyValue.RawData[(1 + (curveName == "P256" ? 32 : 48))..],
            },
        });
        using var withKey = publicPart.CopyWithPrivateKey(recipient);
        Assert.Equal(GoldenContent, PdfCmsAgreement.Unseal(Convert.FromHexString(envelope), withKey));
    }
}
