using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
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

    [Fact]
    public void An_ocsp_good_dated_after_the_answer_that_carries_it_says_nothing()
    {
        var network = new FakeNetwork { Issued = Pki.Signing.AddDays(1), OcspThisUpdate = Pki.Signing.AddDays(11) };
        var answer = OcspResponse.Parse(AnswerOf(network))!;

        Assert.Equal(RevocationState.NoData, answer.About(Pki.Leaf, Pki.Intermediate).State);
    }

    [Fact]
    public void A_crl_for_ca_certificates_says_nothing_of_one_whose_basic_constraints_do_not_decode()
    {
        using var odd = Pki.IssuedWith("Odd Constraints", new X509Extension("2.5.29.19", [0xFF, 0x01], false));
        var network = new FakeNetwork { CrlExtension = new X509Extension("2.5.29.28", [0x30, 0x03, 0x81, 0x01, 0xFF], true) };
        var crl = Crl.Parse(network.Get(Pki.CrlUrl)!)!;

        Assert.Equal(RevocationState.NoData, crl.About(odd, Pki.Intermediate).State);
    }

    [Fact]
    public void A_crl_issuer_whose_key_usage_does_not_decode_signs_nothing()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest(Pki.Intermediate.SubjectName, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509Extension("2.5.29.15", [0xFF, 0x01], true));
        using var odd = request.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter);
        var crl = Crl.Parse(new FakeNetwork().Get(Pki.CrlUrl)!)!;

        Assert.Equal(RevocationState.NoData, crl.About(Pki.Leaf, odd).State);
    }

    [Fact]
    public void A_certificate_whose_subject_key_identifier_does_not_decode_is_passed_over_when_the_signer_is_looked_for()
    {
        var signed = new SignedCms(new ContentInfo([1, 2, 3]), detached: true);
        signed.ComputeSignature(new CmsSigner(SubjectIdentifierType.SubjectKeyIdentifier, Pki.Leaf) { IncludeOption = X509IncludeOption.EndCertOnly });
        var cms = CmsSignature.Parse(signed.Encode())!;
        using var odd = Pki.IssuedWith("Odd Identifier", new X509Extension("2.5.29.14", [0xFF, 0x01], false));
        cms.Certificates.Insert(0, odd);

        Assert.Equal(Pki.Leaf.Thumbprint, cms.FindSigner()!.Thumbprint);
    }
}
