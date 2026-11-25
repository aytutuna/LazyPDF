using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureClockTests
{
    private static readonly Pki Pki = Pki.Instance;

    [Fact]
    public void Without_a_time_stamp_a_certificate_that_has_since_expired_is_judged_at_the_claimed_time()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.ShortLived, Pki.Signing) { Chain = Pki.Chain });
        var options = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing.AddDays(1) };
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(PdfSignatureVerifier.Verify(signed, options)).Verdict);

        var later = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Expiry.AddDays(10) };
        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, later));
        Assert.Contains(SignatureProblem.CertificateExpired, report.Problems);
        Assert.DoesNotContain(SignatureProblem.CertificateNotValid, report.Problems);
        Assert.Equal(Pki.Signing, report.TimeUsed);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.EndsWith("The certificate has expired since.", report.Sentence);
    }

    [Fact]
    public void A_claimed_time_before_the_certificate_began_is_not_valid()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.ShortLived, Pki.NotBefore.AddDays(-30)) { Chain = Pki.Chain });
        var options = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Expiry.AddDays(10) };

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, options));

        Assert.Contains(SignatureProblem.CertificateNotValid, report.Problems);
        Assert.DoesNotContain(SignatureProblem.CertificateExpired, report.Problems);
    }

    [Fact]
    public void A_claimed_time_before_1601_is_not_valid_and_does_not_throw()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.Leaf, new DateTimeOffset(1500, 1, 1, 0, 0, 0, TimeSpan.Zero)) { Chain = Pki.Chain });

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing }));

        Assert.Contains(SignatureProblem.CertificateNotValid, report.Problems);
    }

    [Fact]
    public void A_stamped_signature_is_not_flagged_for_a_certificate_that_has_since_expired()
    {
        var network = new FakeNetwork { StampTime = Pki.Signing.AddMinutes(1) };
        var request = new PdfSignRequest(Pki.ShortLived, Pki.Signing) { Chain = Pki.Chain, Timestamp = new TimestampSettings(network, "http://tsa.test/") };
        var options = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Expiry.AddDays(10) };

        var report = Assert.Single(PdfSignatureVerifier.Verify(PdfSigner.Sign(SignatureKit.Plain(), request), options));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Empty(report.Problems);
    }

    [Fact]
    public void A_revocation_between_the_claim_and_now_still_counts()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        byte[] archived = PdfLongTermValidation.Add(signed, new FakeNetwork { Revoked = true, RevokedAt = Pki.Signing.AddDays(30) }, Pki.Signing);
        var later = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing.AddDays(60) };

        var report = Assert.Single(PdfSignatureVerifier.Verify(archived, later));

        Assert.Contains(SignatureProblem.CertificateRevoked, report.Problems);
        Assert.Equal(Pki.Signing, report.TimeUsed);
    }
}