using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>A certificate revocation list (RFC 5280) read far enough to ask whether a serial number is on it.</summary>
internal sealed class Crl
{
    private byte[] _issuer = [];
    private byte[] _tbs = [];
    private string _signatureOid = "";
    private byte[] _signature = [];
    private readonly Dictionary<BigInteger, DateTimeOffset> _revoked = [];

    public DateTimeOffset ThisUpdate { get; private set; }

    public byte[] Raw { get; private set; } = [];

    public static Crl? Parse(byte[] der)
    {
        try
        {
            var list = new AsnReader(der, AsnEncodingRules.BER).ReadSequence();
            var crl = new Crl { Raw = der };
            crl._tbs = list.PeekEncodedValue().ToArray();
            var tbs = list.ReadSequence();
            crl._signatureOid = list.ReadSequence().ReadObjectIdentifier();
            crl._signature = list.ReadBitString(out _);
            if (tbs.PeekTag().TagValue == (int)UniversalTagNumber.Integer) tbs.ReadInteger();
            tbs.ReadSequence();
            crl._issuer = tbs.ReadEncodedValue().ToArray();
            crl.ThisUpdate = ReadTime(tbs);
            if (tbs.HasData && tbs.PeekTag().TagValue is (int)UniversalTagNumber.UtcTime or (int)UniversalTagNumber.GeneralizedTime) ReadTime(tbs);
            if (tbs.HasData && tbs.PeekTag().TagValue == (int)UniversalTagNumber.Sequence)
            {
                var entries = tbs.ReadSequence();
                while (entries.HasData)
                {
                    var entry = entries.ReadSequence();
                    var serial = entry.ReadInteger();
                    crl._revoked.TryAdd(serial, ReadTime(entry));
                }
            }
            return crl;
        }
        catch (Exception e) when (e is AsnContentException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    private static DateTimeOffset ReadTime(AsnReader reader) =>
        reader.PeekTag().TagValue == (int)UniversalTagNumber.UtcTime ? reader.ReadUtcTime() : reader.ReadGeneralizedTime();

    /// <summary>The list is by <paramref name="issuer"/> and carries its signature; the status of <paramref name="certificate"/> on it.</summary>
    public (RevocationState State, DateTimeOffset? RevokedAt) About(X509Certificate2 certificate, X509Certificate2 issuer)
    {
        if (!_issuer.AsSpan().SequenceEqual(issuer.SubjectName.RawData) || !certificate.IssuerName.RawData.AsSpan().SequenceEqual(_issuer)) return (RevocationState.NoData, null);
        var algorithm = Oids.DigestName(OcspResponse.DigestOf(_signatureOid)) ?? HashAlgorithmName.SHA256;
        if (!CmsVerifier.VerifyRaw(issuer, _signatureOid, _signature, _tbs, algorithm)) return (RevocationState.NoData, null);
        return _revoked.TryGetValue(CmsBuilder.Serial(certificate), out var at) ? (RevocationState.Revoked, at) : (RevocationState.Good, null);
    }
}

/// <summary>The places a certificate says to ask: OCSP responders, CRL distribution points and the issuer's certificate.</summary>
internal static class CertificateLinks
{
    private const string AuthorityInfoAccess = "1.3.6.1.5.5.7.1.1";
    private const string CrlDistribution = "2.5.29.31";
    private const string Ocsp = "1.3.6.1.5.5.7.48.1";
    private const string CaIssuers = "1.3.6.1.5.5.7.48.2";

    public static IEnumerable<string> OcspUrls(X509Certificate2 certificate) => AccessUrls(certificate, Ocsp);

    public static IEnumerable<string> IssuerUrls(X509Certificate2 certificate) => AccessUrls(certificate, CaIssuers);

    private static IEnumerable<string> AccessUrls(X509Certificate2 certificate, string method)
    {
        var urls = new List<string>();
        if (certificate.Extensions[AuthorityInfoAccess] is not { } extension) return urls;
        try
        {
            var descriptions = new AsnReader(extension.RawData, AsnEncodingRules.DER).ReadSequence();
            while (descriptions.HasData)
            {
                var description = descriptions.ReadSequence();
                string oid = description.ReadObjectIdentifier();
                if (oid == method && description.PeekTag() is { TagClass: TagClass.ContextSpecific, TagValue: 6 } tag)
                {
                    urls.Add(System.Text.Encoding.ASCII.GetString(description.ReadOctetString(tag)));
                }
                else
                {
                    description.ReadEncodedValue();
                }
            }
        }
        catch (AsnContentException)
        {
            // An extension nobody can read points nowhere.
        }
        return urls;
    }

    public static IEnumerable<string> CrlUrls(X509Certificate2 certificate)
    {
        var urls = new List<string>();
        if (certificate.Extensions[CrlDistribution] is not { } extension) return urls;
        try
        {
            var points = new AsnReader(extension.RawData, AsnEncodingRules.DER).ReadSequence();
            while (points.HasData)
            {
                var point = points.ReadSequence();
                if (!point.HasData || !point.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0, true))) continue;
                var name = point.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true));
                if (!name.HasData || !name.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0, true))) continue;
                var names = name.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true));
                while (names.HasData)
                {
                    if (names.PeekTag() is { TagClass: TagClass.ContextSpecific, TagValue: 6 } tag) urls.Add(System.Text.Encoding.ASCII.GetString(names.ReadOctetString(tag)));
                    else names.ReadEncodedValue();
                }
            }
        }
        catch (AsnContentException)
        {
            // As above.
        }
        return urls;
    }
}
