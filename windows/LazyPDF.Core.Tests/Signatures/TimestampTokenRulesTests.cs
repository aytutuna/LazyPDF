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

    private static X509Certificate2 Authority(bool critical, params string[] purposes) => Authority(Pki.NotBefore, Pki.NotAfter, critical, purposes);

    private static X509Certificate2 Authority(DateTimeOffset notBefore, DateTimeOffset notAfter, bool critical, params string[] purposes)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Authority, O=Lazy Test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        if (purposes.Length > 0)
        {
            var oids = new OidCollection();
            foreach (string purpose in purposes) oids.Add(new Oid(purpose));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(oids, critical));
        }
        using var issuerKey = Pki.Intermediate.GetRSAPrivateKey()!;
        var generator = X509SignatureGenerator.CreateForRSA(issuerKey, RSASignaturePadding.Pkcs1);
        using var signed = request.Create(Pki.Intermediate.SubjectName, generator, notBefore, notAfter, BitConverter.GetBytes(Random.Shared.NextInt64(1_000_000, long.MaxValue)).Reverse().ToArray());
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

    private enum Names { One, Two }

    private static byte[] Ess(X509Certificate2 certificate, bool hashOfOther, bool wrongSerial, Names names = Names.One)
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
                {
                    using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 4))) w.WriteEncodedValue(certificate.IssuerName.RawData);
                    if (names == Names.Two) w.WriteCharacterString(UniversalTagNumber.IA5String, "x.example", new Asn1Tag(TagClass.ContextSpecific, 2));
                }
                w.WriteInteger(new BigInteger(certificate.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true) + (wrongSerial ? 1 : 0));
            }
        }
        return w.Encode();
    }

    /// <summary>The SigningCertificate attribute of RFC 2634, the one with a SHA-1 hash, which RFC 3161 time stamp authorities wrote before RFC 5035.</summary>
    private static byte[] EssV1(X509Certificate2 certificate, bool hashOfOther)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        {
            w.WriteOctetString(SHA1.HashData(hashOfOther ? Pki.Leaf.RawData : certificate.RawData));
        }
        return w.Encode();
    }

    private static byte[] Token(X509Certificate2 authority, X509Certificate2? second = null, bool hashOfOther = false, bool wrongSerial = false, bool withoutEss = false, bool embedded = true, Names names = Names.One, bool v1 = false, bool v1Other = false, bool v2 = true, bool ski = false, bool v2Other = false)
    {
        var cms = new SignedCms(new ContentInfo(new Oid("1.2.840.113549.1.9.16.1.4"), Info()), false);
        foreach (var signerCertificate in new[] { authority, second }.OfType<X509Certificate2>())
        {
            var signer = new CmsSigner(ski ? SubjectIdentifierType.SubjectKeyIdentifier : SubjectIdentifierType.IssuerAndSerialNumber, signerCertificate)
            {
                IncludeOption = embedded ? X509IncludeOption.EndCertOnly : X509IncludeOption.None,
                DigestAlgorithm = new Oid("2.16.840.1.101.3.4.2.1"),
            };
            if (embedded) foreach (var c in Pki.Chain) signer.Certificates.Add(c);
            if (!withoutEss && v2) signer.SignedAttributes.Add(new AsnEncodedData(new Oid(Oids.SigningCertificateV2), Ess(signerCertificate, hashOfOther || v2Other, wrongSerial, names)));
            if (v1) signer.SignedAttributes.Add(new AsnEncodedData(new Oid("1.2.840.113549.1.9.16.2.12"), EssV1(signerCertificate, v1Other)));
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

    [Fact]
    public void The_authority_certificate_has_to_hold_at_the_time_of_the_stamp()
    {
        using var expired = Authority(Pki.NotBefore, Pki.Signing.AddDays(-1), true, TimeStamping);
        using var later = Authority(Pki.Signing.AddDays(1), Pki.NotAfter, true, TimeStamping);
        using var holding = Authority(Pki.Signing.AddDays(-1), Pki.Signing.AddDays(1), true, TimeStamping);

        Assert.False(Accepts(Token(expired)));
        Assert.False(Accepts(Token(later)));
        Assert.True(Accepts(Token(holding)));
        Assert.False(Accepts(Token(expired, embedded: false), expired));
        Assert.False(Accepts(Token(later, embedded: false), later));
        Assert.True(Accepts(Token(holding, embedded: false), holding));
    }

    [Fact]
    public void A_token_may_name_its_signer_with_the_SHA1_signing_certificate_alone()
    {
        using var critical = Authority(true, TimeStamping);

        Assert.True(Accepts(Token(critical, v1: true, v2: false)));
        Assert.True(Accepts(Token(critical, v1: true, v2: true)));
        Assert.False(Accepts(Token(critical, v1: true, v1Other: true, v2: true)));
        Assert.False(Accepts(Token(critical, v1: true, v1Other: true, v2: false)));
        Assert.False(Accepts(Token(critical, v1: true, v2Other: true, v2: true)));
    }

    [Fact]
    public void A_signer_named_by_its_key_identifier_is_checked_against_the_certificate_when_there_is_one()
    {
        using var critical = Authority(true, TimeStamping);

        Assert.True(Accepts(Token(critical, ski: true)));
        Assert.True(Accepts(Token(critical, ski: true, embedded: false), critical));
        Assert.False(Accepts(Token(critical, ski: true, wrongSerial: true)));
    }

    [Fact]
    public void The_issuer_serial_names_exactly_one_issuer()
    {
        using var critical = Authority(true, TimeStamping);

        Assert.False(Accepts(Token(critical, names: Names.Two)));
    }
}
