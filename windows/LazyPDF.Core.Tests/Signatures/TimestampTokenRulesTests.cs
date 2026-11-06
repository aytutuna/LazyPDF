using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>What Rfc3161TimestampToken accepts as the signer of a time stamp: the purposes of the certificate, the number of signers and the ESSCertID.</summary>
public class TimestampTokenRulesTests
{
    private static readonly Pki Pki = Pki.Instance;
    private const string TimeStamping = "1.3.6.1.5.5.7.3.8";
    private const string EmailProtection = "1.3.6.1.5.5.7.3.4";
    private static readonly byte[] Hash = SHA256.HashData([1, 2, 3]);

    private static X509Certificate2 Authority(bool critical, params string[] purposes)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Authority, O=Lazy Test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        if (purposes.Length > 0)
        {
            var oids = new OidCollection();
            foreach (string purpose in purposes) oids.Add(new Oid(purpose));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(oids, critical));
        }
        using var issuerKey = Pki.Intermediate.GetRSAPrivateKey()!;
        var generator = X509SignatureGenerator.CreateForRSA(issuerKey, RSASignaturePadding.Pkcs1);
        using var signed = request.Create(Pki.Intermediate.SubjectName, generator, Pki.NotBefore, Pki.NotAfter, BitConverter.GetBytes(Random.Shared.NextInt64(1_000_000, long.MaxValue)).Reverse().ToArray());
        return signed.CopyWithPrivateKey(key);
    }

    private static byte[] Info()
    {
        var info = new AsnWriter(AsnEncodingRules.DER);
        using (info.PushSequence())
        {
            info.WriteInteger(1);
            info.WriteObjectIdentifier("1.2.3.4.1");
            using (info.PushSequence())
            {
                using (info.PushSequence())
                {
                    info.WriteObjectIdentifier("2.16.840.1.101.3.4.2.1");
                    info.WriteNull();
                }
                info.WriteOctetString(Hash);
            }
            info.WriteInteger(77);
            info.WriteGeneralizedTime(Pki.Signing, omitFractionalSeconds: true);
        }
        return info.Encode();
    }

    private static byte[] Ess(X509Certificate2 certificate, bool hashOfOther, bool wrongSerial)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        {
            w.WriteOctetString(SHA256.HashData(hashOfOther ? Pki.Leaf.RawData : certificate.RawData));
            using (w.PushSequence())
            {
                using (w.PushSequence())
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 4)))
                {
                    w.WriteEncodedValue(certificate.IssuerName.RawData);
                }
                w.WriteInteger(new BigInteger(certificate.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true) + (wrongSerial ? 1 : 0));
            }
        }
        return w.Encode();
    }

    private static byte[] Token(X509Certificate2 authority, X509Certificate2? second = null, bool hashOfOther = false, bool wrongSerial = false, bool withoutEss = false, bool embedded = true)
    {
        var cms = new SignedCms(new ContentInfo(new Oid("1.2.840.113549.1.9.16.1.4"), Info()), false);
        foreach (var signerCertificate in new[] { authority, second }.OfType<X509Certificate2>())
        {
            var signer = new CmsSigner(SubjectIdentifierType.IssuerAndSerialNumber, signerCertificate)
            {
                IncludeOption = embedded ? X509IncludeOption.EndCertOnly : X509IncludeOption.None,
                DigestAlgorithm = new Oid("2.16.840.1.101.3.4.2.1"),
            };
            if (embedded) foreach (var c in Pki.Chain) signer.Certificates.Add(c);
            if (!withoutEss) signer.SignedAttributes.Add(new AsnEncodedData(new Oid(Oids.SigningCertificateV2), Ess(signerCertificate, hashOfOther, wrongSerial)));
            cms.ComputeSignature(signer);
        }
        return cms.Encode();
    }

    private static bool Accepts(byte[] token, params X509Certificate2[] extra) =>
        Rfc3161TimestampToken.TryDecode(token, out var decoded, out _) && decoded is not null
        && decoded.VerifySignatureForHash(Hash, HashAlgorithmName.SHA256, out var tsa, new X509Certificate2Collection(extra)) && tsa is not null;

    [Fact]
    public void The_authority_has_the_time_stamping_purpose_in_one_critical_extension()
    {
        using var critical = Authority(true, TimeStamping);
        using var criticalTwo = Authority(true, TimeStamping, EmailProtection);
        using var quiet = Authority(false, TimeStamping);
        using var quietTwo = Authority(false, TimeStamping, EmailProtection);
        using var none = Authority(false);

        Assert.True(Accepts(Token(critical)));
        Assert.True(Accepts(Token(criticalTwo)));
        Assert.False(Accepts(Token(quiet)));
        Assert.False(Accepts(Token(quietTwo)));
        Assert.False(Accepts(Token(none)));
    }

    [Fact]
    public void An_authority_that_is_not_in_the_token_is_judged_the_same_way()
    {
        using var critical = Authority(true, TimeStamping);
        using var quiet = Authority(false, TimeStamping);
        using var none = Authority(false);

        Assert.True(Accepts(Token(critical, embedded: false), critical));
        Assert.False(Accepts(Token(critical, embedded: false)));
        Assert.False(Accepts(Token(quiet, embedded: false), quiet));
        Assert.False(Accepts(Token(none, embedded: false), none));
    }

    [Fact]
    public void A_token_has_one_signer_and_names_its_certificate_exactly()
    {
        using var critical = Authority(true, TimeStamping);
        using var other = Authority(true, TimeStamping);

        Assert.False(Accepts(Token(critical, other)));
        Assert.False(Accepts(Token(critical, hashOfOther: true)));
        Assert.False(Accepts(Token(critical, wrongSerial: true)));
        Assert.False(Accepts(Token(critical, wrongSerial: true, embedded: false), critical));
        Assert.False(Accepts(Token(critical, withoutEss: true)));
    }
}
