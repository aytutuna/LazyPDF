using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Certificates, answers and parameters in a file that do not decode, and a responder that expired after it answered.</summary>
public class SignatureMalformedDataTests
{
    private static readonly Pki Pki = Pki.Instance;

    private const string OcspSigning = "1.3.6.1.5.5.7.3.9";

    private static byte[] AnswerOf(FakeNetwork network) =>
        network.Post(Pki.OcspUrl, "application/ocsp-request", OcspResponse.BuildRequest(Pki.Leaf, Pki.Intermediate))!;

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void A_responder_that_expired_after_it_answered_still_counts(bool revoked)
    {
        using var responder = Pki.IssuedUntil(Pki.Expiry, "Short Responder", X509KeyUsageFlags.DigitalSignature, OcspSigning);
        var answer = OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = responder, Revoked = revoked, Issued = Pki.Signing.AddDays(1) }))!;

        var state = answer.About(Pki.Leaf, Pki.Intermediate).State;

        Assert.Equal(revoked ? RevocationState.Revoked : RevocationState.Good, state);
    }

    [Fact]
    public void A_responder_that_was_not_valid_when_it_answered_says_nothing()
    {
        using var responder = Pki.IssuedUntil(Pki.Expiry, "Short Responder", X509KeyUsageFlags.DigitalSignature, OcspSigning);
        var answer = OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = responder, Issued = Pki.Expiry.AddDays(30) }))!;

        Assert.Equal(RevocationState.NoData, answer.About(Pki.Leaf, Pki.Intermediate).State);
    }

    [Theory]
    [InlineData("2.5.29.15")]
    [InlineData("2.5.29.37")]
    public void A_signer_certificate_with_an_extension_that_does_not_decode_is_untrusted_not_fatal(string oid)
    {
        using var odd = Pki.IssuedWith("Odd Signer", new X509Extension(oid, [0xFF, 0x01], false));
        byte[] first = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));

        byte[] second = PdfSigner.Sign(first, new PdfSignRequest(odd, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });
        var reports = SignatureKit.Verify(second);

        Assert.Equal(2, reports.Count);
        Assert.Contains(SignatureProblem.UntrustedSigner, reports[1].Problems);
    }

    [Fact]
    public void An_ocsp_answer_whose_certificate_has_a_purpose_that_does_not_decode_says_nothing()
    {
        using var responder = Pki.IssuedWith("Odd Responder", new X509Extension("2.5.29.37", [0xFF, 0x01], false));
        var answer = OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = responder }))!;

        Assert.Equal(RevocationState.NoData, answer.About(Pki.Leaf, Pki.Intermediate).State);
    }

    [Fact]
    public void PSS_parameters_with_a_universal_tag_break_that_signature_and_nothing_else()
    {
        byte[] file = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Format = SignatureFormat.Pkcs7Detached });
        byte[] forged = SignatureKit.Splice(file, content =>
        {
            byte[] cms = SignatureVerificationTests.ByFramework(content, Pki.Leaf, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
            int at = cms.AsSpan().IndexOf(new byte[] { 0xA2, 0x03, 0x02, 0x01, 0x20 });
            Assert.True(at > 0);
            cms[at] = 0x02;
            return cms;
        });
        byte[] second = PdfSigner.Sign(forged, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });

        var reports = SignatureKit.Verify(second);

        Assert.Equal(SignatureVerdict.Broken, reports[0].Verdict);
        Assert.Equal(SignatureVerdict.Valid, reports[1].Verdict);
    }

    [Fact]
    public void Archived_revocation_data_with_a_universal_tag_adds_nothing()
    {
        byte[] file = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        var cms = CmsSignature.Parse(SignatureKit.Parts(file).Cms)!;
        var archival = new AsnWriter(AsnEncodingRules.DER);
        using (archival.PushSequence()) archival.WriteInteger(0);
        cms.Attributes[Oids.RevocationArchival] = [archival.Encode()];

        var data = new ValidationData();
        data.ReadArchival(cms);

        Assert.Empty(data.Ocsps);
        Assert.Empty(data.Crls);
    }
}
