using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The servers named by a signer's certificate, found without asking any of them.
public sealed class ServerPreviewTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    internal static byte[] Signed(string ocsp, string crl)
    {
        using var rootKey = RSA.Create(2048);
        var rootRequest = new CertificateRequest("CN=Test Root", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        using var root = rootRequest.CreateSelfSigned(Now.AddYears(-1), Now.AddYears(5));

        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Ada Lovelace", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(AuthorityInfoAccess(ocsp));
        request.CertificateExtensions.Add(CrlDistribution(crl));
        using var issued = request.Create(root, Now.AddDays(-1), Now.AddYears(1), [1, 2, 3, 4]);
        using var leaf = issued.CopyWithPrivateKey(key);

        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, new PdfSignRequest(leaf, Now) { Chain = [leaf, root] });
        return session.Current.ToArray();
    }

    private static X509Extension AuthorityInfoAccess(string ocsp)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier("1.3.6.1.5.5.7.48.1");
            w.WriteCharacterString(UniversalTagNumber.IA5String, ocsp, new Asn1Tag(TagClass.ContextSpecific, 6));
        }
        return new X509Extension("1.3.6.1.5.5.7.1.1", w.Encode(), false);
    }

    private static X509Extension CrlDistribution(string url)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
        using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
        {
            w.WriteCharacterString(UniversalTagNumber.IA5String, url, new Asn1Tag(TagClass.ContextSpecific, 6));
        }
        return new X509Extension("2.5.29.31", w.Encode(), false);
    }

    [Fact]
    public async Task HostsComeInTheOrderAskedWithPlainHttpMarked()
    {
        var file = Signed("http://ocsp.test/ocsp", "https://crl.test:8443/ca.crl");

        var hosts = await ServerPreview.HostsAsync(file, null);

        Assert.Equal(["ocsp.test (not encrypted)", "crl.test:8443"], hosts);
    }

    [Fact]
    public async Task AnUnsignedFileNamesNoServer()
    {
        Assert.Empty(await ServerPreview.HostsAsync(Pdfs.Text(), null));
    }

    [Fact]
    public void LongListsEndWithTheCountLeftOut()
    {
        var hosts = Enumerable.Range(1, 8).Select(i => $"s{i}.test").ToList();

        Assert.Equal("s1.test, s2.test, s3.test, s4.test, s5.test, s6.test, and 2 more", ServerPreview.Describe(hosts));
        Assert.Equal("s1.test, s2.test", ServerPreview.Describe(hosts.Take(2).ToList()));
    }
}
