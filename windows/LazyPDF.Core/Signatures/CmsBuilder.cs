using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

internal static class Oids
{
    public const string Data = "1.2.840.113549.1.7.1";
    public const string SignedData = "1.2.840.113549.1.7.2";
    public const string ContentType = "1.2.840.113549.1.9.3";
    public const string MessageDigest = "1.2.840.113549.1.9.4";
    public const string SigningTime = "1.2.840.113549.1.9.5";
    public const string SigningCertificateV2 = "1.2.840.113549.1.9.16.2.47";
    public const string TimestampToken = "1.2.840.113549.1.9.16.2.14";
    public const string RevocationArchival = "1.2.840.113583.1.1.8";
    public const string TstInfo = "1.2.840.113549.1.9.16.1.4";
    public const string RsaEncryption = "1.2.840.113549.1.1.1";
    public const string RsaPss = "1.2.840.113549.1.1.10";
    public const string EcPublicKey = "1.2.840.10045.2.1";

    public static string Digest(HashAlgorithmName name) => name.Name switch
    {
        "SHA256" => "2.16.840.1.101.3.4.2.1",
        "SHA384" => "2.16.840.1.101.3.4.2.2",
        "SHA512" => "2.16.840.1.101.3.4.2.3",
        _ => throw new ArgumentException("Only SHA-256, SHA-384 and SHA-512 sign.", nameof(name)),
    };

    public static HashAlgorithmName? DigestName(string oid) => oid switch
    {
        "1.3.14.3.2.26" => HashAlgorithmName.SHA1,
        "2.16.840.1.101.3.4.2.1" => HashAlgorithmName.SHA256,
        "2.16.840.1.101.3.4.2.2" => HashAlgorithmName.SHA384,
        "2.16.840.1.101.3.4.2.3" => HashAlgorithmName.SHA512,
        _ => null,
    };

    public static string EcdsaWith(HashAlgorithmName name) => name.Name switch
    {
        "SHA256" => "1.2.840.10045.4.3.2",
        "SHA384" => "1.2.840.10045.4.3.3",
        _ => "1.2.840.10045.4.3.4",
    };
}

/// <summary>What the CMS needs besides the digest: who signs, with what, and in which flavour.</summary>
internal sealed record CmsSettings(X509Certificate2 Certificate, IReadOnlyList<X509Certificate2> Chain, HashAlgorithmName Digest,
                                   bool Cades, DateTimeOffset Time, PdfHashSigner? External);

// A detached CMS SignedData (RFC 5652) written by hand: System.Security.Cryptography.Pkcs signs only
// with a key it holds, and a token behind a delegate has to sign the hash we give it.
internal static class CmsBuilder
{
    /// <param name="timestamp">Gets the signature value and returns an encoded time stamp token, or null; added as an unsigned attribute.</param>
    public static byte[] Build(byte[] contentDigest, CmsSettings s, Func<byte[], byte[]?>? timestamp)
    {
        var certificate = s.Certificate;
        var attributes = new List<byte[]>
        {
            Attribute(Oids.ContentType, w => w.WriteObjectIdentifier(Oids.Data)),
            Attribute(Oids.MessageDigest, w => w.WriteOctetString(contentDigest)),
            Attribute(Oids.SigningCertificateV2, w => WriteSigningCertificate(w, certificate)),
        };
        // PAdES leaves the signing time to /M; the older profile has it in the signature.
        if (!s.Cades) attributes.Add(Attribute(Oids.SigningTime, w => w.WriteUtcTime(s.Time.ToUniversalTime())));

        byte[] signedAttributes = WriteSet(attributes, null);
        byte[] hash = HashData(s.Digest, signedAttributes);
        var (signature, algorithm) = Sign(hash, s);
        byte[]? token = timestamp?.Invoke(signature);

        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier(Oids.SignedData);
            using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
            using (w.PushSequence())
            {
                w.WriteInteger(1);
                using (w.PushSetOf()) WriteAlgorithm(w, Oids.Digest(s.Digest), withNull: true);
                using (w.PushSequence())
                {
                    w.WriteObjectIdentifier(Oids.Data);
                }
                using (w.PushSetOf(new Asn1Tag(TagClass.ContextSpecific, 0)))
                {
                    foreach (var c in Embedded(s)) w.WriteEncodedValue(c.RawData);
                }
                using (w.PushSetOf())
                using (w.PushSequence())
                {
                    w.WriteInteger(1);
                    using (w.PushSequence())
                    {
                        w.WriteEncodedValue(certificate.IssuerName.RawData);
                        w.WriteInteger(Serial(certificate));
                    }
                    WriteAlgorithm(w, Oids.Digest(s.Digest), withNull: true);
                    w.WriteEncodedValue(WriteSet(attributes, new Asn1Tag(TagClass.ContextSpecific, 0)));
                    w.WriteEncodedValue(algorithm);
                    w.WriteOctetString(signature);
                    if (token is not null)
                    {
                        var unsigned = new List<byte[]> { Attribute(Oids.TimestampToken, x => x.WriteEncodedValue(token)) };
                        w.WriteEncodedValue(WriteSet(unsigned, new Asn1Tag(TagClass.ContextSpecific, 1)));
                    }
                }
            }
        }
        return w.Encode();
    }

    public static byte[] HashData(HashAlgorithmName algorithm, ReadOnlySpan<byte> data) => algorithm.Name switch
    {
        "SHA1" => SHA1.HashData(data),
        "SHA256" => SHA256.HashData(data),
        "SHA384" => SHA384.HashData(data),
        "SHA512" => SHA512.HashData(data),
        _ => throw new ArgumentException("Unknown digest.", nameof(algorithm)),
    };

    public static BigInteger Serial(X509Certificate2 certificate) =>
        new(certificate.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true);

    private static IEnumerable<X509Certificate2> Embedded(CmsSettings s)
    {
        var seen = new HashSet<string> { s.Certificate.Thumbprint };
        yield return s.Certificate;
        foreach (var c in s.Chain)
        {
            if (seen.Add(c.Thumbprint)) yield return c;
        }
    }

    private static (byte[] Signature, byte[] Algorithm) Sign(byte[] hash, CmsSettings s)
    {
        var certificate = s.Certificate;
        bool ec = certificate.PublicKey.Oid.Value == Oids.EcPublicKey;
        byte[] raw;
        if (s.External is { } external)
        {
            raw = external(hash, s.Digest);
        }
        else if (ec)
        {
            using var key = certificate.GetECDsaPrivateKey() ?? throw new InvalidOperationException(SignatureText.NoPrivateKey);
            raw = key.SignHash(hash, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        else
        {
            using var key = certificate.GetRSAPrivateKey() ?? throw new InvalidOperationException(SignatureText.NoPrivateKey);
            raw = key.SignHash(hash, s.Digest, RSASignaturePadding.Pkcs1);
        }

        var algorithm = new AsnWriter(AsnEncodingRules.DER);
        if (ec)
        {
            WriteAlgorithm(algorithm, Oids.EcdsaWith(s.Digest), withNull: false);
            return (EcdsaDer(raw), algorithm.Encode());
        }
        WriteAlgorithm(algorithm, Oids.RsaEncryption, withNull: true);
        return (raw, algorithm.Encode());
    }

    private static byte[] EcdsaDer(byte[] p1363)
    {
        int half = p1363.Length / 2;
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            // Either half may start with zero bytes, which DER integers do not keep.
            w.WriteInteger(new BigInteger(p1363.AsSpan(0, half), isUnsigned: true, isBigEndian: true));
            w.WriteInteger(new BigInteger(p1363.AsSpan(half), isUnsigned: true, isBigEndian: true));
        }
        return w.Encode();
    }

    private static void WriteAlgorithm(AsnWriter w, string oid, bool withNull)
    {
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier(oid);
            if (withNull) w.WriteNull();
        }
    }

    private static byte[] Attribute(string oid, Action<AsnWriter> value)
    {
        var inner = new AsnWriter(AsnEncodingRules.DER);
        value(inner);
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier(oid);
            using (w.PushSetOf()) w.WriteEncodedValue(inner.Encode());
        }
        return w.Encode();
    }

    // The signature is made over this encoding with the universal SET tag; in the SignerInfo it carries a context tag.
    private static byte[] WriteSet(List<byte[]> items, Asn1Tag? tag)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSetOf(tag))
        {
            foreach (byte[] item in items) w.WriteEncodedValue(item);
        }
        return w.Encode();
    }

    // ESSCertIDv2 (RFC 5035); the hash algorithm is left out when it is SHA-256, its DEFAULT.
    internal static void WriteSigningCertificate(AsnWriter w, X509Certificate2 certificate)
    {
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        {
            w.WriteOctetString(SHA256.HashData(certificate.RawData));
            using (w.PushSequence())
            {
                using (w.PushSequence())
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 4)))
                {
                    w.WriteEncodedValue(certificate.IssuerName.RawData);
                }
                w.WriteInteger(Serial(certificate));
            }
        }
    }
}
