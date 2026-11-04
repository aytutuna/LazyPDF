using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureClockTests
{
    private static readonly Pki Pki = Pki.Instance;

    [Fact]
    public void Without_a_time_stamp_a_certificate_that_has_since_expired_is_not_trusted()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.ShortLived, Pki.Signing) { Chain = Pki.Chain });
        var options = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing.AddDays(1) };
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(PdfSignatureVerifier.Verify(signed, options)).Verdict);

        var later = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Expiry.AddDays(10) };
        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, later));
        Assert.Contains(SignatureProblem.CertificateNotValid, report.Problems);
    }
}
