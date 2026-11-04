using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>The request after a field's seed values (ISO 32000-1 12.7.4.5) have had their say.</summary>
internal sealed class SignJob
{
    public SignJob(PdfSignRequest request)
    {
        Request = request;
        Format = request.Format;
        Digest = request.Digest;
        Reason = request.Reason;
        Certify = request.Certify;
        Lock = request.Lock;
        Level = request.Timestamp is not null && request.Level == PadesLevel.B ? PadesLevel.T : request.Level;
        TimestampUrl = request.Timestamp?.Url;
        Name = request.Name ?? CertificateName(request.Certificate);
    }

    public PdfSignRequest Request { get; }
    public SignatureFormat Format { get; set; }
    public HashAlgorithmName Digest { get; set; }
    public string? Reason { get; set; }
    public CertificationLevel Certify { get; set; }
    public FieldLock? Lock { get; set; }
    public PadesLevel Level { get; set; }
    public string? TimestampUrl { get; set; }
    public string Name { get; }

    public static string CertificateName(X509Certificate2 certificate) =>
        certificate.GetNameInfo(X509NameType.SimpleName, false) is { Length: > 0 } name ? name : certificate.Subject;
}

// Only the seed values that decide how a signature is made are obeyed; the rest (legal attestation,
// the URL and policy tests of /Cert) are refused outright when the field marks them required.
internal static class SeedValues
{
    private static readonly string[] SupportedFilters = ["ETSI.CAdES.detached", "adbe.pkcs7.detached"];

    public static void Apply(PdfDocument document, PdfDictionary field, SignJob job)
    {
        if (document.Dict(field, "SV") is not { } sv) return;
        long flags = document.Integer(sv, "Ff") ?? 0;
        bool Required(int bit) => (flags & (1L << (bit - 1))) != 0;

        if (Required(1) && document.Name(sv, "Filter") is { } filter && filter != "Adobe.PPKLite") throw new InvalidOperationException(SignatureText.SeedUnsupported);

        if (document.Array(sv, "SubFilter") is { } subFilters)
        {
            var names = subFilters.Items.Select(i => (document.Resolve(i) as PdfName)?.Value).OfType<string>().ToList();
            string current = job.Format == SignatureFormat.CadesDetached ? "ETSI.CAdES.detached" : "adbe.pkcs7.detached";
            if (Required(2) && !names.Contains(current))
            {
                string? chosen = names.FirstOrDefault(n => SupportedFilters.Contains(n));
                if (chosen is null) throw new InvalidOperationException(SignatureText.SeedFormat);
                job.Format = chosen == "ETSI.CAdES.detached" ? SignatureFormat.CadesDetached : SignatureFormat.Pkcs7Detached;
            }
        }

        if (document.Array(sv, "Reasons") is { } reasons)
        {
            var list = reasons.Items.Select(i => PdfText.Read(document, i)).OfType<string>().ToList();
            if (Required(4) && list.Count > 0)
            {
                if (job.Reason is null) job.Reason = list[0];
                else if (!list.Contains(job.Reason)) throw new InvalidOperationException(SignatureText.SeedReason);
            }
        }

        if (Required(5) && document.Array(sv, "LegalAttestation") is { Items.Count: > 0 }) throw new InvalidOperationException(SignatureText.SeedUnsupported);

        if (Required(6) && document.Bool(sv, "AddRevInfo") == true && job.Level < PadesLevel.LT)
        {
            if (job.Request.Timestamp is null) throw new InvalidOperationException(SignatureText.NoTimestampServer);
            job.Level = PadesLevel.LT;
        }

        if (Required(7) && document.Array(sv, "DigestMethod") is { } digests)
        {
            var names = digests.Items.Select(i => (document.Resolve(i) as PdfName)?.Value).OfType<string>().ToList();
            string current = job.Digest.Name!;
            if (!names.Contains(current))
            {
                string? chosen = names.FirstOrDefault(n => n is "SHA256" or "SHA384" or "SHA512");
                if (chosen is null) throw new InvalidOperationException(SignatureText.SeedDigest);
                job.Digest = new HashAlgorithmName(chosen);
            }
        }

        if (document.Dict(sv, "MDP") is { } mdp && document.Integer(mdp, "P") is { } p)
        {
            if (p == 0 && job.Certify != CertificationLevel.None) throw new InvalidOperationException(SignatureText.SeedCertification);
            if (p is >= 1 and <= 3)
            {
                if (job.Certify != CertificationLevel.None && (int)job.Certify != p) throw new InvalidOperationException(SignatureText.SeedCertification);
                job.Certify = (CertificationLevel)p;
            }
        }

        if (document.Dict(sv, "TimeStamp") is { } stamp)
        {
            bool required = document.Integer(stamp, "Ff") == 1;
            if (required && job.Request.Timestamp is null) throw new InvalidOperationException(SignatureText.NoTimestampServer);
            if (job.Request.Timestamp is not null) job.TimestampUrl ??= PdfText.Read(document, stamp["URL"]);
        }

        if (document.Dict(sv, "Cert") is { } cert) CheckCertificate(document, cert, job);
    }

    private static void CheckCertificate(PdfDocument document, PdfDictionary cert, SignJob job)
    {
        long flags = document.Integer(cert, "Ff") ?? 0;
        bool Required(int bit) => (flags & (1L << (bit - 1))) != 0;
        var certificate = job.Request.Certificate;

        if (Required(1) && !Certificates(document, cert["Subject"]).Any(c => c.RawData.AsSpan().SequenceEqual(certificate.RawData))) throw new InvalidOperationException(SignatureText.SeedCertificate);
        if (Required(2))
        {
            var issuers = Certificates(document, cert["Issuer"]).Select(c => c.SubjectName.RawData).ToList();
            var chain = new List<X509Certificate2>(job.Request.Chain) { certificate };
            if (!chain.Any(c => issuers.Any(i => i.AsSpan().SequenceEqual(c.IssuerName.RawData)))) throw new InvalidOperationException(SignatureText.SeedCertificate);
        }
        if (Required(3) || Required(6)) throw new InvalidOperationException(SignatureText.SeedUnsupported);
        if (Required(4) && document.Array(cert, "SubjectDN") is { } dns && !dns.Items.Select(document.Resolve).OfType<PdfDictionary>().Any(d => MatchesName(document, d, certificate))) throw new InvalidOperationException(SignatureText.SeedCertificate);
        if (Required(5) && document.Array(cert, "KeyUsage") is { } usages && !usages.Items.Select(i => PdfText.Read(document, i)).OfType<string>().Any(u => MatchesUsage(u, certificate))) throw new InvalidOperationException(SignatureText.SeedCertificate);
    }

    private static IEnumerable<X509Certificate2> Certificates(PdfDocument document, PdfObject? array)
    {
        if (document.Resolve(array) is not PdfArray items) yield break;
        foreach (var item in items.Items)
        {
            X509Certificate2? loaded = null;
            try
            {
                if (document.Resolve(item) is PdfString { Bytes: var bytes }) loaded = X509CertificateLoader.LoadCertificate(bytes);
            }
            catch (CryptographicException)
            {
                // A seed entry that is not a certificate matches nothing.
            }
            if (loaded is not null) yield return loaded;
        }
    }

    private static bool MatchesName(PdfDocument document, PdfDictionary wanted, X509Certificate2 certificate)
    {
        var present = new List<(string Oid, string Value)>();
        foreach (var rdn in certificate.SubjectName.EnumerateRelativeDistinguishedNames())
        {
            present.Add((rdn.GetSingleElementType().Value ?? "", rdn.GetSingleElementValue() ?? ""));
        }
        foreach (var (key, value) in wanted.Entries)
        {
            string oid = key switch { "C" => "2.5.4.6", "O" => "2.5.4.10", "OU" => "2.5.4.11", "CN" => "2.5.4.3", "L" => "2.5.4.7", "ST" => "2.5.4.8", "E" => "1.2.840.113549.1.9.1", _ => key };
            if (PdfText.Read(document, value) is not { } text || !present.Any(p => p.Oid == oid && p.Value == text)) return false;
        }
        return true;
    }

    // Nine characters, one per key usage bit from digitalSignature: 1 must be set, 0 must be clear, X does not matter.
    private static bool MatchesUsage(string pattern, X509Certificate2 certificate)
    {
        var usage = certificate.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault()?.KeyUsages ?? X509KeyUsageFlags.None;
        X509KeyUsageFlags[] bits =
        [
            X509KeyUsageFlags.DigitalSignature, X509KeyUsageFlags.NonRepudiation, X509KeyUsageFlags.KeyEncipherment,
            X509KeyUsageFlags.DataEncipherment, X509KeyUsageFlags.KeyAgreement, X509KeyUsageFlags.KeyCertSign,
            X509KeyUsageFlags.CrlSign, X509KeyUsageFlags.EncipherOnly, X509KeyUsageFlags.DecipherOnly,
        ];
        for (int i = 0; i < Math.Min(pattern.Length, bits.Length); i++)
        {
            bool set = (usage & bits[i]) != 0;
            if ((pattern[i] == '1' && !set) || (pattern[i] == '0' && set)) return false;
        }
        return true;
    }
}
