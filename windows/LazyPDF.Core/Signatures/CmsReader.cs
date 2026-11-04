using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>The first signer of a CMS SignedData, as far as verifying needs it.</summary>
internal sealed class CmsSignature
{
    public int Length { get; private init; }
    public List<X509Certificate2> Certificates { get; } = [];
    public string DigestOid { get; private set; } = "";
    public byte[]? SignedAttributes { get; private set; }
    public Dictionary<string, List<byte[]>> Attributes { get; } = [];
    public Dictionary<string, List<byte[]>> UnsignedAttributes { get; } = [];
    public string SignatureOid { get; private set; } = "";
    public byte[] SignatureParameters { get; private set; } = [];
    public byte[] Signature { get; private set; } = [];
    public byte[]? IssuerName { get; private set; }
    public BigInteger Serial { get; private set; }
    public byte[]? KeyId { get; private set; }
    public byte[]? Content { get; private set; }

    /// <summary>Reads the ContentInfo at the start of <paramref name="data"/>; null when it is not a SignedData with a signer.</summary>
    public static CmsSignature? Parse(ReadOnlySpan<byte> data)
    {
        try
        {
            var reader = new AsnReader(data.ToArray(), AsnEncodingRules.BER);
            int length = reader.PeekEncodedValue().Length;
            var info = reader.ReadSequence();
            if (info.ReadObjectIdentifier() != Oids.SignedData) return null;
            var signed = info.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0)).ReadSequence();
            var result = new CmsSignature { Length = length };
            signed.ReadInteger();
            signed.ReadSetOf(skipSortOrderValidation: true);
            var encapsulated = signed.ReadSequence();
            encapsulated.ReadObjectIdentifier();
            if (encapsulated.HasData) result.Content = encapsulated.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0)).ReadOctetString();
            if (signed.HasData && signed.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
            {
                var certificates = signed.ReadSetOf(true, new Asn1Tag(TagClass.ContextSpecific, 0));
                while (certificates.HasData)
                {
                    byte[] encoded = certificates.ReadEncodedValue().ToArray();
                    if (encoded[0] != 0x30) continue;
                    try { result.Certificates.Add(X509CertificateLoader.LoadCertificate(encoded)); }
                    catch (CryptographicException) { }
                }
            }
            if (signed.HasData && signed.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 1))) signed.ReadEncodedValue();
            var signers = signed.ReadSetOf(skipSortOrderValidation: true);
            if (!signers.HasData) return null;
            result.ReadSigner(signers.ReadSequence());
            return result;
        }
        catch (Exception e) when (e is AsnContentException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    private void ReadSigner(AsnReader signer)
    {
        signer.ReadInteger();
        if (signer.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
        {
            KeyId = signer.ReadOctetString(new Asn1Tag(TagClass.ContextSpecific, 0));
        }
        else
        {
            var id = signer.ReadSequence();
            IssuerName = id.ReadEncodedValue().ToArray();
            Serial = id.ReadInteger();
        }
        DigestOid = signer.ReadSequence().ReadObjectIdentifier();
        var tag = new Asn1Tag(TagClass.ContextSpecific, 0);
        if (signer.PeekTag().HasSameClassAndValue(tag))
        {
            // Signed over the DER of the set, with the universal tag instead of the implicit one.
            SignedAttributes = signer.PeekEncodedValue().ToArray();
            SignedAttributes[0] = 0x31;
            ReadAttributes(signer.ReadSetOf(true, tag), Attributes);
        }
        var algorithm = signer.ReadSequence();
        SignatureOid = algorithm.ReadObjectIdentifier();
        SignatureParameters = algorithm.HasData ? algorithm.ReadEncodedValue().ToArray() : [];
        Signature = signer.ReadOctetString();
        var unsignedTag = new Asn1Tag(TagClass.ContextSpecific, 1);
        if (signer.HasData && signer.PeekTag().HasSameClassAndValue(unsignedTag))
        {
            ReadAttributes(signer.ReadSetOf(true, unsignedTag), UnsignedAttributes);
        }
    }

    private static void ReadAttributes(AsnReader set, Dictionary<string, List<byte[]>> into)
    {
        while (set.HasData)
        {
            var attribute = set.ReadSequence();
            string oid = attribute.ReadObjectIdentifier();
            var values = attribute.ReadSetOf(skipSortOrderValidation: true);
            if (!into.TryGetValue(oid, out var list)) into[oid] = list = [];
            while (values.HasData) list.Add(values.ReadEncodedValue().ToArray());
        }
    }

    /// <summary>The signer's certificate among the embedded ones, null when it is not in the signature.</summary>
    public X509Certificate2? FindSigner()
    {
        foreach (var c in Certificates)
        {
            if (IssuerName is not null)
            {
                if (c.IssuerName.RawData.AsSpan().SequenceEqual(IssuerName) && CmsBuilder.Serial(c) == Serial) return c;
            }
            else if (KeyId is not null && KeyIdentifier(c) is { } id && id.AsSpan().SequenceEqual(KeyId))
            {
                return c;
            }
        }
        return null;
    }

    private static byte[]? KeyIdentifier(X509Certificate2 certificate)
    {
        try
        {
            return certificate.Extensions.OfType<X509SubjectKeyIdentifierExtension>().FirstOrDefault() is { } ski ? Convert.FromHexString(ski.SubjectKeyIdentifier!) : null;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    /// <summary>
    /// The signing-certificate-v2 attribute (RFC 5035), when there is one, names the signer's certificate by hash;
    /// false when it names another, which would let a signature be moved to a different certificate.
    /// </summary>
    public bool SigningCertificateMatches(X509Certificate2 signer)
    {
        if (!Attributes.TryGetValue(Oids.SigningCertificateV2, out var values) || values.Count != 1) return true;
        try
        {
            var ids = new AsnReader(values[0], AsnEncodingRules.BER).ReadSequence().ReadSequence();
            var id = ids.ReadSequence();
            var algorithm = HashAlgorithmName.SHA256;
            if (id.PeekTag().TagValue == (int)UniversalTagNumber.Sequence)
            {
                algorithm = Oids.DigestName(id.ReadSequence().ReadObjectIdentifier()) ?? HashAlgorithmName.SHA256;
            }
            return CmsBuilder.HashData(algorithm, signer.RawData).AsSpan().SequenceEqual(id.ReadOctetString());
        }
        catch (AsnContentException)
        {
            return false;
        }
    }

    /// <summary>The content digest the signer's attributes name; null without one.</summary>
    public byte[]? MessageDigest()
    {
        if (!Attributes.TryGetValue(Oids.MessageDigest, out var values) || values.Count != 1) return null;
        try { return new AsnReader(values[0], AsnEncodingRules.BER).ReadOctetString(); }
        catch (AsnContentException) { return null; }
    }

    public DateTimeOffset? SigningTime()
    {
        if (!Attributes.TryGetValue(Oids.SigningTime, out var values) || values.Count != 1) return null;
        try
        {
            var reader = new AsnReader(values[0], AsnEncodingRules.BER);
            return reader.PeekTag().TagValue == (int)UniversalTagNumber.UtcTime ? reader.ReadUtcTime() : reader.ReadGeneralizedTime();
        }
        catch (AsnContentException) { return null; }
    }
}

internal enum CmsCheck
{
    Ok,
    DigestMismatch,
    BadSignature,
    Unsupported,
}

internal static class CmsVerifier
{
    /// <summary>Checks the message digest against <paramref name="contentDigest"/> (made with the signer's own digest algorithm) and the signature with the certificate's key.</summary>
    public static CmsCheck Check(CmsSignature cms, X509Certificate2 signer, Func<HashAlgorithmName, byte[]> contentDigest)
    {
        if (Oids.DigestName(cms.DigestOid) is not { } algorithm) return CmsCheck.Unsupported;
        // Without signed attributes the signature is over the content's digest itself (RFC 5652 5.4).
        byte[] hash;
        if (cms.SignedAttributes is { } attributes)
        {
            if (cms.MessageDigest() is not { } expected || !CryptographicOperations.FixedTimeEquals(expected, contentDigest(algorithm))) return CmsCheck.DigestMismatch;
            hash = CmsBuilder.HashData(algorithm, attributes);
        }
        else
        {
            hash = contentDigest(algorithm);
        }
        try
        {
            return cms.SignatureOid switch
            {
                Oids.RsaPss => VerifyPss(cms, signer, hash, algorithm),
                var oid when oid.StartsWith("1.2.840.113549.1.1.", StringComparison.Ordinal) => VerifyRsa(signer, hash, algorithm, cms.Signature, RSASignaturePadding.Pkcs1),
                var oid when oid.StartsWith("1.2.840.10045.4.", StringComparison.Ordinal) => VerifyEcdsa(signer, hash, cms.Signature),
                _ => CmsCheck.Unsupported,
            };
        }
        catch (Exception e) when (e is CryptographicException or AsnContentException or OverflowException or ArgumentException)
        {
            return CmsCheck.BadSignature;
        }
    }

    public static bool VerifyRaw(X509Certificate2 issuer, string signatureOid, byte[] signature, byte[] signed, HashAlgorithmName algorithm)
    {
        byte[] hash = CmsBuilder.HashData(algorithm, signed);
        try
        {
            return signatureOid.StartsWith("1.2.840.10045.4.", StringComparison.Ordinal)
                ? VerifyEcdsa(issuer, hash, signature) == CmsCheck.Ok
                : VerifyRsa(issuer, hash, algorithm, signature, RSASignaturePadding.Pkcs1) == CmsCheck.Ok;
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    private static CmsCheck VerifyRsa(X509Certificate2 signer, byte[] hash, HashAlgorithmName algorithm, byte[] signature, RSASignaturePadding padding)
    {
        using var key = signer.GetRSAPublicKey();
        if (key is null) return CmsCheck.BadSignature;
        return key.VerifyHash(hash, signature, algorithm, padding) ? CmsCheck.Ok : CmsCheck.BadSignature;
    }

    private static CmsCheck VerifyEcdsa(X509Certificate2 signer, byte[] hash, byte[] signature)
    {
        using var key = signer.GetECDsaPublicKey();
        if (key is null) return CmsCheck.BadSignature;
        return key.VerifyHash(hash, signature, DSASignatureFormat.Rfc3279DerSequence) ? CmsCheck.Ok : CmsCheck.BadSignature;
    }

    // RSASSA-PSS-params (RFC 4055): .NET takes a salt as long as the digest, which is what PDF signers use.
    private static CmsCheck VerifyPss(CmsSignature cms, X509Certificate2 signer, byte[] hash, HashAlgorithmName algorithm)
    {
        int saltLength = 20;
        if (cms.SignatureParameters.Length > 0)
        {
            var parameters = new AsnReader(cms.SignatureParameters, AsnEncodingRules.BER).ReadSequence();
            while (parameters.HasData)
            {
                var tag = parameters.PeekTag();
                var field = parameters.ReadSequence(tag);
                if (tag.TagValue == 2) saltLength = (int)field.ReadInteger();
            }
        }
        if (saltLength != hash.Length) return CmsCheck.Unsupported;
        return VerifyRsa(signer, hash, algorithm, cms.Signature, RSASignaturePadding.Pss);
    }
}
