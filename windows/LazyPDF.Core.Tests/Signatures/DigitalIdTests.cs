using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class DigitalIdTests
{
    private static readonly DateTimeOffset Start = new(2026, 3, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void A_digital_id_is_a_self_signed_certificate_for_signing_with_its_key()
    {
        using var id = PdfDigitalId.Create("Ada Lovelace", "ada@example.org", Start, years: 5, keyBits: 2048);

        Assert.True(id.HasPrivateKey);
        Assert.Equal("Ada Lovelace", id.GetNameInfo(X509NameType.SimpleName, false));
        Assert.Equal("ada@example.org", id.GetNameInfo(X509NameType.EmailName, false));
        Assert.Equal(id.SubjectName.RawData, id.IssuerName.RawData);
        Assert.Equal(Start.UtcDateTime, id.NotBefore.ToUniversalTime());
        Assert.Equal(Start.AddYears(5).UtcDateTime, id.NotAfter.ToUniversalTime());
        Assert.Equal(2048, id.GetRSAPublicKey()!.KeySize);
        var usage = id.Extensions.OfType<X509KeyUsageExtension>().Single().KeyUsages;
        Assert.Equal(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation, usage);
        Assert.False(id.Extensions.OfType<X509BasicConstraintsExtension>().Single().CertificateAuthority);
    }

    [Fact]
    public void The_pfx_carries_the_key_and_loads_again()
    {
        using var id = PdfDigitalId.Create("Ada Lovelace", null, Start, keyBits: 2048);

        byte[] pfx = PdfDigitalId.ExportPfx(id, "pass word");
        using var loaded = PdfDigitalId.ImportPfx(pfx, "pass word");

        Assert.Equal(id.Thumbprint, loaded.Thumbprint);
        Assert.True(loaded.HasPrivateKey);
        Assert.ThrowsAny<CryptographicException>(() => PdfDigitalId.ImportPfx(pfx, "wrong"));
    }

    [Fact]
    public void Names_with_commas_quotes_and_Turkish_letters_survive()
    {
        const string Name = "Doğan, \"Şık\" Ü.";
        using var id = PdfDigitalId.Create(Name, null, Start, keyBits: 2048);

        Assert.Equal(Name, id.GetNameInfo(X509NameType.SimpleName, false));
    }

    [Fact]
    public void A_signature_with_it_is_valid_but_not_trusted_until_the_caller_trusts_it()
    {
        using var id = PdfDigitalId.Create("Ada Lovelace", null, Start, keyBits: 2048);
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(id, Start.AddDays(3)));

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed));
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Equal("Signed by Ada Lovelace on 4 Mar 2026. The signer is not trusted.", report.Sentence);

        var trusted = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { TrustAnchors = [id] }));
        Assert.Equal(SignatureVerdict.Valid, trusted.Verdict);
    }

    [Fact]
    public void A_signature_by_a_certificate_the_caller_trusts_is_valid_though_its_issuer_is_not_an_anchor()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.Instance.Leaf, Pki.Signing));

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { TrustAnchors = [Pki.Instance.Leaf], Now = Pki.Signing }));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }
}
