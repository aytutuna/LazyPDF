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
}
