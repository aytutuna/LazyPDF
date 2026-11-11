using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class IssuerFetchTests
{
    private static readonly Pki Pki = Pki.Instance;

    private sealed class Answering(Func<string, byte[]?> answer) : ISignatureTransport
    {
        public int Gets { get; private set; }

        public byte[]? Post(string url, string contentType, byte[] body) => null;

        public byte[]? Get(string url)
        {
            Gets++;
            return answer(url);
        }
    }

    // The signer's own certificate only: the intermediate is neither in the signature nor in a /DSS.
    private static byte[] SignedWithoutIntermediate(bool withRoot = false) =>
        PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Chain = withRoot ? [Pki.Root] : [] });

    private static SignatureReport Verify(byte[] file, ISignatureTransport? transport) =>
        Assert.Single(PdfSignatureVerifier.Verify(file, Pki.Trusting with { Now = Pki.Signing, Transport = transport }));

    [Fact]
    public void A_signer_whose_issuer_is_only_reachable_by_link_is_untrusted_without_a_transport()
    {
        var report = Verify(SignedWithoutIntermediate(), null);

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
    }

    [Fact]
    public void A_transport_fetches_the_missing_issuer_and_the_signer_is_valid()
    {
        var network = new FakeNetwork();

        var report = Verify(SignedWithoutIntermediate(), network);

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.DoesNotContain(SignatureProblem.UntrustedSigner, report.Problems);
        Assert.Contains(Pki.IssuerUrl, network.Requests);
    }

    [Fact]
    public void A_fetched_certificate_alone_trusts_nothing()
    {
        var network = new FakeNetwork();
        var options = new VerifyOptions { Now = Pki.Signing, Transport = network };

        var report = Assert.Single(PdfSignatureVerifier.Verify(SignedWithoutIntermediate(withRoot: true), options));

        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
    }

    [Fact]
    public void Garbage_or_nothing_from_the_transport_leaves_the_signer_untrusted()
    {
        byte[] file = SignedWithoutIntermediate();

        foreach (var transport in new[] { new Answering(_ => null), new Answering(_ => [1, 2, 3, 4]) })
        {
            var report = Verify(file, transport);

            Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
            Assert.True(transport.Gets > 0);
        }
    }

    [Fact]
    public void The_transport_is_not_asked_when_the_chain_is_complete()
    {
        var network = new Answering(_ => throw new InvalidOperationException("asked"));
        byte[] file = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));

        var report = Verify(file, network);

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(0, network.Gets);
    }

    [Fact]
    public void Fetching_stops_after_four_certificates()
    {
        var endless = new Answering(_ =>
        {
            using var key = RSA.Create(2048);
            var request = new CertificateRequest("CN=Elsewhere", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            return request.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter).RawData;
        });

        var report = Verify(SignedWithoutIntermediate(), endless);

        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
        Assert.Equal(4, endless.Gets);
    }
}
