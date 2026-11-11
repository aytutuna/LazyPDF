using System.Formats.Asn1;
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

    [Fact]
    public void A_signer_in_the_anchors_is_trusted_whatever_signed_it()
    {
        var options = new VerifyOptions { TrustAnchors = [Pki.Leaf] };

        var result = CertificateTrust.Evaluate(Pki.Leaf, [], Pki.Signing, options);

        Assert.True(result.Trusted);
        Assert.True(result.TimeValid);
        Assert.Single(result.Chain);
        Assert.False(CertificateTrust.Evaluate(Pki.LeafEc, [], Pki.Signing, options).Trusted);
    }

    [Fact]
    public void A_signer_in_the_anchors_keeps_its_full_chain_when_a_root_is_trusted_too()
    {
        var result = CertificateTrust.Evaluate(Pki.Leaf, Pki.Chain, Pki.Signing, new VerifyOptions { TrustAnchors = [Pki.Root, Pki.Leaf] });

        Assert.True(result.Trusted);
        Assert.True(result.Chain.Count > 1);
    }

    [Fact]
    public void A_signer_in_the_anchors_the_system_store_does_not_know_is_trusted_by_itself()
    {
        var result = CertificateTrust.Evaluate(Pki.Leaf, [], Pki.Signing, new VerifyOptions { TrustAnchors = [Pki.Leaf], UseSystemStore = true });

        Assert.True(result.Trusted);
        Assert.Single(result.Chain);
    }

    [Fact]
    public void A_signer_in_the_anchors_still_needs_a_key_usage_for_signing()
    {
        using var encipher = Pki.Issued("Encipher", X509KeyUsageFlags.KeyEncipherment);

        Assert.False(CertificateTrust.Evaluate(encipher, [], Pki.Signing, new VerifyOptions { TrustAnchors = [encipher] }).Trusted);
    }

    [Fact]
    public void A_signer_in_the_anchors_is_not_time_valid_after_it_expires()
    {
        var result = CertificateTrust.Evaluate(Pki.ShortLived, [], Pki.Expiry.AddDays(1), new VerifyOptions { TrustAnchors = [Pki.ShortLived] });

        Assert.True(result.Trusted);
        Assert.False(result.TimeValid);
    }

    private sealed class PssGenerator(RSA key, byte[] algorithm, bool spoil) : X509SignatureGenerator
    {
        protected override PublicKey BuildPublicKey() => PublicKey.CreateFromSubjectPublicKeyInfo(key.ExportSubjectPublicKeyInfo(), out _);

        public override byte[] GetSignatureAlgorithmIdentifier(HashAlgorithmName hashAlgorithm) => algorithm;

        public override byte[] SignData(byte[] data, HashAlgorithmName hashAlgorithm)
        {
            if (spoil) data = [.. data, 0];
            return key.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
        }
    }

    // RSASSA-PSS-params naming SHA-256, the mask function given, the salt given and, when asked, a trailer field.
    private static byte[] PssAlgorithm(string maskOid, string maskHashOid, int salt, int? trailer)
    {
        const string Sha256Oid = "2.16.840.1.101.3.4.2.1";
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier("1.2.840.113549.1.1.10");
            using (w.PushSequence())
            {
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)))
                using (w.PushSequence()) w.WriteObjectIdentifier(Sha256Oid);
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 1, true)))
                using (w.PushSequence())
                {
                    w.WriteObjectIdentifier(maskOid);
                    using (w.PushSequence()) w.WriteObjectIdentifier(maskHashOid);
                }
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 2, true))) w.WriteInteger(salt);
                if (trailer is { } t)
                {
                    using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 3, true))) w.WriteInteger(t);
                }
            }
        }
        return w.Encode();
    }

    private static bool PssRootTrusted(byte[] algorithm, bool spoil)
    {
        using var rootKey = RSA.Create(2048);
        var rootRequest = new CertificateRequest("CN=Pss Variant", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
        using var rootBare = rootRequest.Create(rootRequest.SubjectName, new PssGenerator(rootKey, algorithm, spoil), Pki.NotBefore, Pki.NotAfter, [7, 7, 7]);
        using var rootWithKey = rootBare.CopyWithPrivateKey(rootKey);
        var root = X509CertificateLoader.LoadCertificate(rootBare.RawData);

        using var leafKey = RSA.Create(2048);
        var leafRequest = new CertificateRequest("CN=Pss Variant Leaf", leafKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        using var signed = leafRequest.Create(rootWithKey, Pki.NotBefore, Pki.NotAfter, [1, 2, 3, 6]);
        using var leaf = signed.CopyWithPrivateKey(leafKey);
        return CertificateTrust.Evaluate(leaf, [], Pki.Signing, new VerifyOptions { TrustAnchors = [root] }).Trusted;
    }

    [Fact]
    public void A_PSS_root_is_trusted_only_with_the_mask_function_salt_and_signature_it_declares()
    {
        const string Mgf1 = "1.2.840.113549.1.1.8", Sha1Oid = "1.3.14.3.2.26", Sha256Oid = "2.16.840.1.101.3.4.2.1";

        Assert.True(PssRootTrusted(PssAlgorithm(Mgf1, Sha256Oid, 32, null), false));
        Assert.False(PssRootTrusted(PssAlgorithm(Mgf1, Sha1Oid, 32, null), false));
        Assert.False(PssRootTrusted(PssAlgorithm("1.2.3.4", Sha256Oid, 32, null), false));
        Assert.False(PssRootTrusted(PssAlgorithm(Mgf1, Sha256Oid, 32, 2), false));
        Assert.True(PssRootTrusted(PssAlgorithm(Mgf1, Sha256Oid, 32, 1), false));
        Assert.False(PssRootTrusted(PssAlgorithm(Mgf1, Sha256Oid, 20, null), false));
        Assert.False(PssRootTrusted(PssAlgorithm(Mgf1, Sha256Oid, 32, null), true));
    }
}
