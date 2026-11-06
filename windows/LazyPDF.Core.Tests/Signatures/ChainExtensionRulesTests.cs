using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Extensions of a certificate in the chain that decide whether the signer is trusted. The Swift twin is SignatureChainRulesTests.</summary>
public class ChainExtensionRulesTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly byte[] EmptySequence = [0x30, 0x00];

    // certificatePolicies with the anyPolicy identifier.
    private static readonly byte[] AnyPolicy = [0x30, 0x08, 0x30, 0x06, 0x06, 0x04, 0x55, 0x1D, 0x20, 0x00];

    private static bool Trusted(string oid, byte[] value, bool critical)
    {
        using var certificate = Pki.IssuedWith("Extension", new X509Extension(oid, value, critical));
        return CertificateTrust.Evaluate(certificate, Pki.Chain, Pki.Signing, Pki.Trusting).Trusted;
    }

    [Fact]
    public void A_critical_extension_that_is_not_known_makes_the_chain_untrusted()
    {
        Assert.True(Trusted("1.2.3.4.5", EmptySequence, false));
        Assert.False(Trusted("1.2.3.4.5", EmptySequence, true));
    }

    [Fact]
    public void A_critical_subject_directory_attributes_extension_makes_the_chain_untrusted()
    {
        Assert.True(Trusted("2.5.29.9", EmptySequence, false));
        Assert.False(Trusted("2.5.29.9", EmptySequence, true));
    }

    [Fact]
    public void Certificate_policies_that_do_not_decode_make_the_chain_untrusted()
    {
        Assert.True(Trusted("2.5.29.32", AnyPolicy, false));
        Assert.False(Trusted("2.5.29.32", [0xFF, 0x01], false));
        Assert.False(Trusted("2.5.29.32", [0xFF, 0x01], true));
    }

    private static (X509Certificate2 Root, X509Certificate2 Leaf) PssChain()
    {
        using var rootKey = RSA.Create(2048);
        var rootRequest = new CertificateRequest("CN=Pss Root", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
        using var rootWithKey = rootRequest.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter);
        var root = X509CertificateLoader.LoadCertificate(rootWithKey.RawData);

        using var leafKey = RSA.Create(2048);
        var leafRequest = new CertificateRequest("CN=Pss Leaf", leafKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        using var signed = leafRequest.Create(rootWithKey, Pki.NotBefore, Pki.NotAfter, [1, 2, 3, 4]);
        return (root, signed.CopyWithPrivateKey(leafKey));
    }

    [Fact]
    public void A_root_signed_with_PSS_is_trusted_when_the_caller_trusts_it()
    {
        var (root, leaf) = PssChain();

        Assert.True(CertificateTrust.Evaluate(leaf, [], Pki.Signing, new VerifyOptions { TrustAnchors = [root] }).Trusted);
    }

    [Fact]
    public void A_link_certificate_with_the_name_of_the_root_ends_the_chain_as_an_anchor_whatever_else_is_trusted()
    {
        using var linkKey = RSA.Create(2048);
        var linkRequest = new CertificateRequest("CN=Test Root", linkKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        linkRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        linkRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
        linkRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(linkRequest.PublicKey, false));
        using var linkSigned = linkRequest.Create(Pki.Root, Pki.NotBefore, Pki.NotAfter, [9, 9, 9]);
        using var link = linkSigned.CopyWithPrivateKey(linkKey);

        using var leafKey = RSA.Create(2048);
        var leafRequest = new CertificateRequest("CN=Under Link", leafKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        using var leaf = leafRequest.Create(link, Pki.NotBefore, Pki.NotAfter, [1, 2, 3, 5]);

        Assert.False(CertificateTrust.Evaluate(leaf, [link], Pki.Signing, new VerifyOptions { TrustAnchors = [link, Pki.Root] }).Trusted);
        Assert.False(CertificateTrust.Evaluate(leaf, [link], Pki.Signing, new VerifyOptions { TrustAnchors = [link] }).Trusted);
    }
}
