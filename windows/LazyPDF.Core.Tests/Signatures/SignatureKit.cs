using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

/// <summary>A small CA chain, a signer of each key type, a time stamp authority and a self-signed certificate, made once for all tests.</summary>
internal sealed class Pki
{
    public const string OcspUrl = "http://ocsp.test/ocsp";
    public const string CrlUrl = "http://crl.test/intermediate.crl";
    public const string RootCrlUrl = "http://crl.test/root.crl";
    public const string IssuerUrl = "http://ca.test/intermediate.cer";

    public static readonly DateTimeOffset NotBefore = new(2025, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public static readonly DateTimeOffset NotAfter = new(2040, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public static readonly DateTimeOffset Expiry = new(2026, 6, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>A moment all certificates are valid at.</summary>
    public static readonly DateTimeOffset Signing = new(2026, 3, 10, 9, 30, 0, TimeSpan.Zero);

    private static readonly Lazy<Pki> Shared = new(() => new Pki());

    public static Pki Instance => Shared.Value;

    private Pki()
    {
        Root = Ca("Test Root", null);
        Intermediate = Ca("Test Intermediate", Root);
        Leaf = MakeLeaf("Ada Lovelace", rsa: true, withLinks: true);
        LeafEc = MakeLeaf("Grace Hopper", rsa: false, withLinks: false);
        Tsa = MakeLeaf("Test Time Stamp Authority", rsa: true, withLinks: false, timestamping: true);
        SelfSigned = SelfSignedLeaf("Self Signer");
        ShortLived = MakeLeaf("Short Lived", rsa: true, withLinks: false, notAfter: Expiry);
        Chain = [Intermediate, Root];
    }

    public X509Certificate2 Root { get; }
    public X509Certificate2 Intermediate { get; }
    public X509Certificate2 Leaf { get; }
    public X509Certificate2 LeafEc { get; }
    public X509Certificate2 Tsa { get; }
    public X509Certificate2 SelfSigned { get; }

    /// <summary>A signer whose certificate ran out on <see cref="Expiry"/>.</summary>
    public X509Certificate2 ShortLived { get; }
    public IReadOnlyList<X509Certificate2> Chain { get; }

    public VerifyOptions Trusting => new() { TrustAnchors = [Root] };

    private static long _serial = 1000;

    private static X509Certificate2 Ca(string name, X509Certificate2? issuer)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        if (issuer is null) return request.CreateSelfSigned(NotBefore, NotAfter);
        request.CertificateExtensions.Add(CrlDistribution(RootCrlUrl));
        using var signed = request.Create(issuer, NotBefore, NotAfter, SerialBytes());
        return signed.CopyWithPrivateKey(key);
    }

    private X509Certificate2 MakeLeaf(string name, bool rsa, bool withLinks, bool timestamping = false, DateTimeOffset? notAfter = null)
    {
        using var rsaKey = rsa ? RSA.Create(2048) : null;
        using var ecKey = rsa ? null : ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = rsa
            ? new CertificateRequest($"CN={name}, O=Lazy Test", rsaKey!, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            : new CertificateRequest($"CN={name}, O=Lazy Test", ecKey!, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        if (timestamping)
        {
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.8")], true));
        }
        if (withLinks)
        {
            request.CertificateExtensions.Add(AuthorityInfoAccess());
            request.CertificateExtensions.Add(CrlDistribution(CrlUrl));
        }
        using var issuerKey = Intermediate.GetRSAPrivateKey()!;
        var generator = X509SignatureGenerator.CreateForRSA(issuerKey, RSASignaturePadding.Pkcs1);
        using var signed = request.Create(Intermediate.SubjectName, generator, NotBefore, notAfter ?? NotAfter, SerialBytes());
        return rsa ? signed.CopyWithPrivateKey(rsaKey!) : signed.CopyWithPrivateKey(ecKey!);
    }

    /// <summary>A certificate under the intermediate with the given key usage and purposes, for those that must not count as a signer, a time stamp authority or an OCSP responder.</summary>
    public X509Certificate2 Issued(string name, X509KeyUsageFlags usage, params string[] purposes) => Issue(name, usage, NotAfter, null, purposes);

    /// <summary>Like <see cref="Issued"/>, valid until <paramref name="notAfter"/>.</summary>
    public X509Certificate2 IssuedUntil(DateTimeOffset notAfter, string name, X509KeyUsageFlags usage, params string[] purposes) => Issue(name, usage, notAfter, null, purposes);

    /// <summary>A certificate for signing that also carries <paramref name="extension"/>, which may not decode.</summary>
    public X509Certificate2 IssuedWith(string name, X509Extension extension) => Issue(name, X509KeyUsageFlags.DigitalSignature, NotAfter, extension);

    private X509Certificate2 Issue(string name, X509KeyUsageFlags usage, DateTimeOffset notAfter, X509Extension? extension, params string[] purposes)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}, O=Lazy Test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        if (extension?.Oid?.Value != "2.5.29.19") request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        if (extension?.Oid?.Value != "2.5.29.15") request.CertificateExtensions.Add(new X509KeyUsageExtension(usage, true));
        var oids = new OidCollection();
        foreach (string purpose in purposes) oids.Add(new Oid(purpose));
        if (oids.Count > 0) request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(oids, false));
        if (extension is not null) request.CertificateExtensions.Add(extension);
        using var issuerKey = Intermediate.GetRSAPrivateKey()!;
        var generator = X509SignatureGenerator.CreateForRSA(issuerKey, RSASignaturePadding.Pkcs1);
        using var signed = request.Create(Intermediate.SubjectName, generator, NotBefore, notAfter, SerialBytes());
        return signed.CopyWithPrivateKey(key);
    }

    private static X509Certificate2 SelfSignedLeaf(string name)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        return request.CreateSelfSigned(NotBefore, NotAfter);
    }

    private static byte[] SerialBytes() => BitConverter.GetBytes(Interlocked.Increment(ref _serial)).Reverse().ToArray();

    private static X509Extension AuthorityInfoAccess()
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            foreach (var (oid, url) in new[] { ("1.3.6.1.5.5.7.48.1", OcspUrl), ("1.3.6.1.5.5.7.48.2", IssuerUrl) })
            {
                using (w.PushSequence())
                {
                    w.WriteObjectIdentifier(oid);
                    w.WriteCharacterString(UniversalTagNumber.IA5String, url, new Asn1Tag(TagClass.ContextSpecific, 6));
                }
            }
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
}

/// <summary>A byte range, a time stamp server, an OCSP responder and a CRL host in one transport, offline.</summary>
internal sealed class FakeNetwork : ISignatureTransport
{
    private readonly Pki _pki = Pki.Instance;

    public DateTimeOffset StampTime { get; set; } = Pki.Signing.AddMinutes(1);
    public bool Revoked { get; set; }
    public DateTimeOffset RevokedAt { get; set; } = Pki.Signing.AddDays(-1);
    public bool OcspDown { get; set; }
    public bool CrlDown { get; set; }
    public bool StampDown { get; set; }

    /// <summary>The certificate that signs the OCSP answers when it is not the issuer; it is carried in the answer.</summary>
    public X509Certificate2? Responder { get; set; }

    /// <summary>The certificate that signs the time stamps when it is not the test authority.</summary>
    public X509Certificate2? StampCertificate { get; set; }

    /// <summary>When the OCSP answers and the CRL were issued.</summary>
    public DateTimeOffset Issued { get; set; } = Pki.Signing.AddDays(1);

    public DateTimeOffset? NextUpdate { get; set; }

    /// <summary>The thisUpdate of the OCSP answers when it is not <see cref="Issued"/>.</summary>
    public DateTimeOffset? OcspThisUpdate { get; set; }

    public X509Extension? CrlExtension { get; set; }
    public List<string> Requests { get; } = [];

    public byte[]? Post(string url, string contentType, byte[] body)
    {
        Requests.Add(url);
        if (url == Pki.OcspUrl) return OcspDown ? null : Ocsp(body);
        if (StampDown) return null;
        return Stamp(body);
    }

    public byte[]? Get(string url)
    {
        Requests.Add(url);
        if (url == Pki.IssuerUrl) return _pki.Intermediate.RawData;
        var builder = new CertificateRevocationListBuilder();
        if (url == Pki.RootCrlUrl) return builder.Build(_pki.Root, BigInteger.One, Pki.NotAfter, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1, Pki.Signing.AddDays(1));
        if (url != Pki.CrlUrl || CrlDown) return null;
        if (Revoked) builder.AddEntry(_pki.Leaf.SerialNumberBytes.Span, RevokedAt, X509RevocationReason.KeyCompromise);
        if (CrlExtension is not null) return CrlWithExtension(CrlExtension);
        return builder.Build(_pki.Intermediate, BigInteger.One, NextUpdate ?? Pki.NotAfter, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1, Issued);
    }

    // The framework's builder takes no extensions, so a list with one is written out.
    private byte[] CrlWithExtension(X509Extension extension)
    {
        var tbs = new AsnWriter(AsnEncodingRules.DER);
        using (tbs.PushSequence())
        {
            tbs.WriteInteger(1);
            using (tbs.PushSequence())
            {
                tbs.WriteObjectIdentifier("1.2.840.113549.1.1.11");
                tbs.WriteNull();
            }
            tbs.WriteEncodedValue(_pki.Intermediate.SubjectName.RawData);
            tbs.WriteUtcTime(Issued);
            tbs.WriteUtcTime(NextUpdate ?? Pki.NotAfter);
            if (Revoked)
            {
                using (tbs.PushSequence())
                using (tbs.PushSequence())
                {
                    tbs.WriteInteger(new BigInteger(_pki.Leaf.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true));
                    tbs.WriteUtcTime(RevokedAt);
                }
            }
            using (tbs.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
            using (tbs.PushSequence())
            using (tbs.PushSequence())
            {
                tbs.WriteObjectIdentifier(extension.Oid!.Value!);
                if (extension.Critical) tbs.WriteBoolean(true);
                tbs.WriteOctetString(extension.RawData);
            }
        }
        byte[] body = tbs.Encode();
        using var key = _pki.Intermediate.GetRSAPrivateKey()!;
        var list = new AsnWriter(AsnEncodingRules.DER);
        using (list.PushSequence())
        {
            list.WriteEncodedValue(body);
            using (list.PushSequence())
            {
                list.WriteObjectIdentifier("1.2.840.113549.1.1.11");
                list.WriteNull();
            }
            list.WriteBitString(key.SignData(body, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
        }
        return list.Encode();
    }

    private byte[] Stamp(byte[] request)
    {
        if (!System.Security.Cryptography.Pkcs.Rfc3161TimestampRequest.TryDecode(request, out var parsed, out _)) throw new InvalidOperationException("bad request");
        var info = new AsnWriter(AsnEncodingRules.DER);
        using (info.PushSequence())
        {
            info.WriteInteger(1);
            info.WriteObjectIdentifier("1.2.3.4.1");
            using (info.PushSequence())
            {
                using (info.PushSequence())
                {
                    info.WriteObjectIdentifier(parsed.HashAlgorithmId.Value!);
                    info.WriteNull();
                }
                info.WriteOctetString(parsed.GetMessageHash().Span);
            }
            info.WriteInteger(77);
            info.WriteGeneralizedTime(StampTime, omitFractionalSeconds: true);
            if (parsed.GetNonce() is { } nonce) info.WriteInteger(new BigInteger(nonce.Span, isUnsigned: true, isBigEndian: true));
        }

        var cms = new System.Security.Cryptography.Pkcs.SignedCms(new System.Security.Cryptography.Pkcs.ContentInfo(new Oid("1.2.840.113549.1.9.16.1.4"), info.Encode()), false);
        var authority = StampCertificate ?? _pki.Tsa;
        var signer = new System.Security.Cryptography.Pkcs.CmsSigner(System.Security.Cryptography.Pkcs.SubjectIdentifierType.IssuerAndSerialNumber, authority)
        {
            IncludeOption = X509IncludeOption.EndCertOnly,
            DigestAlgorithm = new Oid("2.16.840.1.101.3.4.2.1"),
        };
        foreach (var c in _pki.Chain) signer.Certificates.Add(c);
        var ess = new AsnWriter(AsnEncodingRules.DER);
        CmsBuilder.WriteSigningCertificate(ess, authority);
        signer.SignedAttributes.Add(new AsnEncodedData(new Oid(Oids.SigningCertificateV2), ess.Encode()));
        cms.ComputeSignature(signer);

        var response = new AsnWriter(AsnEncodingRules.DER);
        using (response.PushSequence())
        {
            using (response.PushSequence()) response.WriteInteger(0);
            response.WriteEncodedValue(cms.Encode());
        }
        return response.Encode();
    }

    private byte[]? Ocsp(byte[] request)
    {
        var reader = new AsnReader(request, AsnEncodingRules.BER).ReadSequence().ReadSequence();
        if (reader.PeekTag().TagClass == TagClass.ContextSpecific) reader.ReadEncodedValue();
        var id = reader.ReadSequence().ReadSequence().ReadSequence();
        id.ReadSequence();
        id.ReadOctetString();
        id.ReadOctetString();
        var serial = id.ReadInteger();
        var issuer = _pki.Intermediate;
        var certificate = _pki.Leaf;
        if (serial != new BigInteger(certificate.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true)) return null;

        var data = new AsnWriter(AsnEncodingRules.DER);
        using (data.PushSequence())
        {
            using (data.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 1))) data.WriteEncodedValue((Responder ?? issuer).SubjectName.RawData);
            data.WriteGeneralizedTime(Issued, omitFractionalSeconds: true);
            using (data.PushSequence())
            using (data.PushSequence())
            {
                using (data.PushSequence())
                {
                    using (data.PushSequence())
                    {
                        data.WriteObjectIdentifier("1.3.14.3.2.26");
                        data.WriteNull();
                    }
                    data.WriteOctetString(SHA1.HashData(issuer.SubjectName.RawData));
                    data.WriteOctetString(SHA1.HashData(issuer.PublicKey.EncodedKeyValue.RawData));
                    data.WriteInteger(serial);
                }
                if (Revoked)
                {
                    using (data.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 1))) data.WriteGeneralizedTime(RevokedAt, omitFractionalSeconds: true);
                }
                else
                {
                    data.WriteNull(new Asn1Tag(TagClass.ContextSpecific, 0));
                }
                data.WriteGeneralizedTime(OcspThisUpdate ?? Issued, omitFractionalSeconds: true);
                if (NextUpdate is { } next)
                {
                    using (data.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0))) data.WriteGeneralizedTime(next, omitFractionalSeconds: true);
                }
            }
        }
        byte[] tbs = data.Encode();
        using var key = (Responder ?? issuer).GetRSAPrivateKey()!;
        byte[] signature = key.SignData(tbs, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        var basic = new AsnWriter(AsnEncodingRules.DER);
        using (basic.PushSequence())
        {
            basic.WriteEncodedValue(tbs);
            using (basic.PushSequence())
            {
                basic.WriteObjectIdentifier("1.2.840.113549.1.1.11");
                basic.WriteNull();
            }
            basic.WriteBitString(signature);
            if (Responder is not null)
            {
                using (basic.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
                using (basic.PushSequence()) basic.WriteEncodedValue(Responder.RawData);
            }
        }
        var response = new AsnWriter(AsnEncodingRules.DER);
        using (response.PushSequence())
        {
            response.WriteEnumeratedValue(OcspStatus.Successful);
            using (response.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
            using (response.PushSequence())
            {
                response.WriteObjectIdentifier("1.3.6.1.5.5.7.48.1.1");
                response.WriteOctetString(basic.Encode());
            }
        }
        return response.Encode();
    }
}

internal static class SignatureKit
{
    /// <summary>Two pages and a font, built the way the other tests build files.</summary>
    public static byte[] Plain(int pages = 2)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{4 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages} /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        for (int i = 0; i < pages; i++) pdf.Obj(4 + i, $"<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 3 0 R>>>> /Contents {4 + pages + i} 0 R>>");
        for (int i = 0; i < pages; i++) pdf.Stream(4 + pages + i, "", $"BT /F1 18 Tf 40 300 Td (Contract page {i + 1}) Tj ET");
        return pdf.Finish();
    }

    public static PdfSignRequest Request(Pki pki) => new(pki.Leaf, Pki.Signing) { Chain = pki.Chain };

    public static IReadOnlyList<SignatureReport> Verify(byte[] file) => PdfSignatureVerifier.Verify(file, Pki.Instance.Trusting);

    /// <summary>The bytes of /Contents and the file without them, as openssl and other tools take them.</summary>
    public static (byte[] Cms, byte[] Signed) Parts(byte[] file, int signature = 0)
    {
        var found = SignatureScan.Find(file)[signature];
        var ranges = (PdfArray)found.Dictionary["ByteRange"]!;
        var n = ranges.Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        byte[] signed = [.. file.AsSpan(n[0], n[1]), .. file.AsSpan(n[2], n[3])];
        var cms = CmsSignature.Parse(((PdfString)found.Dictionary["Contents"]!).Bytes)!;
        return (((PdfString)found.Dictionary["Contents"]!).Bytes[..cms.Length], signed);
    }

    /// <summary>The file with the signature in its first field replaced by <paramref name="make"/>'s CMS over the signed bytes.</summary>
    public static byte[] Splice(byte[] file, Func<byte[], byte[]> make)
    {
        byte[] copy = (byte[])file.Clone();
        var (_, signed) = Parts(copy);
        byte[] cms = make(signed);
        var range = ((PdfArray)SignatureScan.Find(copy)[0].Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        Array.Fill(copy, (byte)'0', range[1] + 1, range[2] - range[1] - 2);
        Encoding.ASCII.GetBytes(Convert.ToHexString(cms), copy.AsSpan(range[1] + 1));
        return copy;
    }

    public static string Text(byte[] bytes) => Encoding.Latin1.GetString(bytes);
}

internal enum OcspStatus
{
    Successful = 0,
}
