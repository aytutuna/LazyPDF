using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

internal enum RevocationState
{
    /// <summary>The data says nothing about the certificate.</summary>
    NoData,
    Good,
    Revoked,
}

/// <summary>The part of an OCSP response (RFC 6960) that matters for a signature: who is answering about which certificate, and what they say.</summary>
internal sealed class OcspResponse
{
    private const string Sha1 = "1.3.14.3.2.26";
    private const string OcspSigning = "1.3.6.1.5.5.7.3.9";

    private sealed record Single(string HashOid, byte[] NameHash, byte[] KeyHash, BigInteger Serial, bool Good, bool Revoked, DateTimeOffset? RevokedAt, DateTimeOffset ThisUpdate, DateTimeOffset? NextUpdate);

    private readonly List<Single> _responses = [];
    private byte[] _tbs = [];
    private string _signatureOid = "";
    private byte[] _signature = [];
    private readonly List<X509Certificate2> _certificates = [];

    public DateTimeOffset ProducedAt { get; private set; }

    public byte[] Raw { get; private set; } = [];

    public static byte[] BuildRequest(X509Certificate2 certificate, X509Certificate2 issuer)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        {
            using (w.PushSequence())
            {
                w.WriteObjectIdentifier(Sha1);
                w.WriteNull();
            }
            w.WriteOctetString(SHA1.HashData(issuer.SubjectName.RawData));
            w.WriteOctetString(SHA1.HashData(issuer.PublicKey.EncodedKeyValue.RawData));
            w.WriteInteger(CmsBuilder.Serial(certificate));
        }
        return w.Encode();
    }

    /// <summary>Reads an OCSPResponse that carries a BasicOCSPResponse; null for anything else, including a response that is not "successful".</summary>
    public static OcspResponse? Parse(byte[] der)
    {
        try
        {
            var response = new AsnReader(der, AsnEncodingRules.BER).ReadSequence();
            if (response.ReadEnumeratedBytes().Span[0] != 0) return null;
            var bytes = response.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0)).ReadSequence();
            bytes.ReadObjectIdentifier();
            var basic = new AsnReader(bytes.ReadOctetString(), AsnEncodingRules.BER).ReadSequence();
            var result = new OcspResponse { _tbs = basic.PeekEncodedValue().ToArray(), Raw = der };
            result.ReadData(basic.ReadSequence());
            result._signatureOid = basic.ReadSequence().ReadObjectIdentifier();
            result._signature = basic.ReadBitString(out _);
            if (basic.HasData)
            {
                var certificates = basic.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0)).ReadSequence();
                while (certificates.HasData)
                {
                    try { result._certificates.Add(X509CertificateLoader.LoadCertificate(certificates.ReadEncodedValue().ToArray())); }
                    catch (CryptographicException) { }
                }
            }
            return result;
        }
        catch (Exception e) when (e is AsnContentException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    private void ReadData(AsnReader data)
    {
        if (data.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) data.ReadEncodedValue();
        data.ReadEncodedValue(); // responderID
        ProducedAt = data.ReadGeneralizedTime();
        var responses = data.ReadSequence();
        while (responses.HasData)
        {
            var single = responses.ReadSequence();
            var id = single.ReadSequence();
            string hashOid = id.ReadSequence().ReadObjectIdentifier();
            byte[] nameHash = id.ReadOctetString(), keyHash = id.ReadOctetString();
            var serial = id.ReadInteger();
            var tag = single.PeekTag();
            bool good = tag.TagValue == 0, revoked = tag.TagValue == 1;
            DateTimeOffset? revokedAt = null;
            if (revoked) revokedAt = single.ReadSequence(tag).ReadGeneralizedTime();
            else single.ReadEncodedValue();
            var thisUpdate = single.ReadGeneralizedTime();
            DateTimeOffset? next = null;
            if (single.HasData && single.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) next = single.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0)).ReadGeneralizedTime();
            _responses.Add(new Single(hashOid, nameHash, keyHash, serial, good, revoked, revokedAt, thisUpdate, next));
        }
    }

    /// <summary>
    /// What the response says of <paramref name="certificate"/> if <paramref name="issuer"/> or a responder it authorised signed it.
    /// With a <paramref name="time"/>, "good" counts only when the response says so for that time (see <see cref="Covers"/>).
    /// </summary>
    public (RevocationState State, DateTimeOffset? RevokedAt, DateTimeOffset ThisUpdate) About(X509Certificate2 certificate, X509Certificate2 issuer, DateTimeOffset? time = null)
    {
        var serial = CmsBuilder.Serial(certificate);
        foreach (var r in _responses)
        {
            if (r.Serial != serial || Oids.DigestName(r.HashOid) is not { } algorithm) continue;
            if (!CmsBuilder.HashData(algorithm, issuer.SubjectName.RawData).AsSpan().SequenceEqual(r.NameHash)
                || !CmsBuilder.HashData(algorithm, issuer.PublicKey.EncodedKeyValue.RawData).AsSpan().SequenceEqual(r.KeyHash)) continue;
            if (!SignedBy(issuer)) return (RevocationState.NoData, null, r.ThisUpdate);
            var state = r.Revoked ? RevocationState.Revoked : r.Good ? RevocationState.Good : RevocationState.NoData;
            if (state == RevocationState.Good && time is { } at && !Covers(r.ThisUpdate, r.NextUpdate, at)) state = RevocationState.NoData;
            return (state, r.RevokedAt, r.ThisUpdate);
        }
        return (RevocationState.NoData, null, default);
    }

    /// <summary>A status holds for <paramref name="time"/> when it was issued then or later, or its validity (RFC 6960 2.4, RFC 5280 5.1.2.5) spans it.</summary>
    public static bool Covers(DateTimeOffset thisUpdate, DateTimeOffset? nextUpdate, DateTimeOffset time) =>
        thisUpdate >= time || (nextUpdate is { } next && next >= time);

    // The issuer itself, or a certificate it issued for answering OCSP (RFC 6960 4.2.2.2) that is in the response.
    private bool SignedBy(X509Certificate2 issuer)
    {
        var algorithm = Oids.DigestName(DigestOf(_signatureOid)) ?? HashAlgorithmName.SHA256;
        if (CmsVerifier.VerifyRaw(issuer, _signatureOid, _signature, _tbs, algorithm)) return true;
        foreach (var candidate in _certificates)
        {
            if (!candidate.IssuerName.RawData.AsSpan().SequenceEqual(issuer.SubjectName.RawData) || ProducedAt < candidate.NotBefore || ProducedAt > candidate.NotAfter) continue;
            if (!MaySignOcsp(candidate) || !IssuedBy(candidate, issuer, ProducedAt)) continue;
            if (CmsVerifier.VerifyRaw(candidate, _signatureOid, _signature, _tbs, algorithm)) return true;
        }
        return false;
    }

    // The responder's certificate has to hold when it answered, whatever the clock says now.
    private static bool MaySignOcsp(X509Certificate2 certificate)
    {
        try { return certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().Any(e => e.EnhancedKeyUsages.Cast<Oid>().Any(o => o.Value == OcspSigning)); }
        catch (CryptographicException) { return false; }
    }

    private static bool IssuedBy(X509Certificate2 certificate, X509Certificate2 issuer, DateTimeOffset producedAt)
    {
        using var chain = new X509Chain();
        chain.ChainPolicy.VerificationTime = producedAt.UtcDateTime;
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(issuer);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.DisableCertificateDownloads = true;
        chain.ChainPolicy.VerificationFlags = X509VerificationFlags.IgnoreEndRevocationUnknown;
        chain.Build(certificate);
        // An issuer that is not a root ends the chain as partial although it is the anchor here.
        var statuses = chain.ChainStatus.Aggregate(X509ChainStatusFlags.NoError, (all, s) => all | s.Status);
        return chain.ChainElements.Count > 1 && chain.ChainElements[1].Certificate.RawData.AsSpan().SequenceEqual(issuer.RawData)
               && (statuses & ~X509ChainStatusFlags.PartialChain) == 0;
    }

    /// <summary>The digest a signature algorithm OID names, as an OID for <see cref="Oids.DigestName"/>.</summary>
    public static string DigestOf(string signatureOid) => signatureOid switch
    {
        "1.2.840.113549.1.1.5" or "1.2.840.10045.4.1" => "1.3.14.3.2.26",
        "1.2.840.113549.1.1.12" or "1.2.840.10045.4.3.3" => "2.16.840.1.101.3.4.2.2",
        "1.2.840.113549.1.1.13" or "1.2.840.10045.4.3.4" => "2.16.840.1.101.3.4.2.3",
        _ => "2.16.840.1.101.3.4.2.1",
    };
}
