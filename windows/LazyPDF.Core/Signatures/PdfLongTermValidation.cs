using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// Adds a /DSS (ETSI EN 319 142-1, PAdES B-LT) to a file: the certificates of every signature's chain, and
/// for each certificate an OCSP response or CRL, as an incremental update, with a /VRI entry per signature. The
/// responders are reached through the caller's transport; a certificate none of them answers for is left without.
/// </summary>
public static class PdfLongTermValidation
{
    private const int MaxChain = 8;

    /// <summary>The file with the validation data added; the same bytes when it already had it all.</summary>
    /// <exception cref="InvalidOperationException">The file has no signature.</exception>
    public static byte[] Add(byte[] pdf, ISignatureTransport transport, DateTimeOffset time, string? password = null)
    {
        var document = PdfDocument.Open(pdf, password);
        Add(document, transport, time);
        return document.SaveIncremental();
    }

    public static void Add(PdfEditSession session, ISignatureTransport transport, DateTimeOffset time)
    {
        Add(session.Document, transport, time);
        session.Commit(Loc.T("Validation data"));
    }

    /// <summary>
    /// The servers <see cref="Add(byte[], ISignatureTransport, DateTimeOffset, string?)"/> would contact for the file's
    /// signatures, without contacting any: OCSP responders and CRL points of each certificate the file's own
    /// certificates chain through, and the issuer links of a chain that stops short of a root. Issuers fetched from
    /// those links may name more servers; data already in /DSS is not subtracted. Each URL once, in order of discovery.
    /// </summary>
    /// <exception cref="InvalidOperationException">The file has no signature.</exception>
    public static IReadOnlyList<ValidationServer> Servers(byte[] pdf, string? password = null) =>
        Servers(PdfDocument.Open(pdf, password));

    public static IReadOnlyList<ValidationServer> Servers(PdfEditSession session) => Servers(session.Document);

    private static List<ValidationServer> Servers(PdfDocument document)
    {
        var signatures = SignatureScan.Find(PdfSigner.SourceBytes(document));
        if (signatures.Count == 0) throw new InvalidOperationException(SignatureText.NotSigned);
        var servers = new List<ValidationServer>();
        void Note(ValidationServerKind kind, string url)
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return;
            if (servers.Any(s => s.Url == url)) return;
            servers.Add(new ValidationServer(kind, url, uri.Host));
        }
        foreach (var found in signatures)
        {
            if (found.Dictionary["Contents"] is not PdfString { Bytes: var contents }) continue;
            foreach (var subject in Subjects(contents, out var pool, out _))
            {
                var chain = BuildChain(subject, pool, Offline.Instance);
                for (int i = 0; i + 1 < chain.Count; i++)
                {
                    foreach (string url in CertificateLinks.OcspUrls(chain[i])) Note(ValidationServerKind.Ocsp, url);
                    foreach (string url in CertificateLinks.CrlUrls(chain[i])) Note(ValidationServerKind.Crl, url);
                }
                var last = chain[^1];
                if (!last.SubjectName.RawData.AsSpan().SequenceEqual(last.IssuerName.RawData))
                    foreach (string url in CertificateLinks.IssuerUrls(last)) Note(ValidationServerKind.CaIssuers, url);
            }
        }
        return servers;
    }

    private sealed class Offline : ISignatureTransport
    {
        public static readonly Offline Instance = new();
        public byte[]? Post(string url, string contentType, byte[] body) => null;
        public byte[]? Get(string url) => null;
    }

    internal static void Add(PdfDocument document, ISignatureTransport transport, DateTimeOffset time)
    {
        var signatures = SignatureScan.Find(PdfSigner.SourceBytes(document));
        if (signatures.Count == 0) throw new InvalidOperationException(SignatureText.NotSigned);
        var dss = new DssWriter(document);
        foreach (var found in signatures)
        {
            if (found.Dictionary["Contents"] is not PdfString { Bytes: var contents }) continue;
            var subjects = Subjects(contents, out var pool, out int length);
            if (subjects.Count == 0) continue;
            var entry = new DssWriter.Entry();
            foreach (var subject in subjects)
            {
                var chain = BuildChain(subject, pool, transport);
                foreach (var certificate in chain) entry.Certificates.Add(dss.Certificate(certificate));
                for (int i = 0; i + 1 < chain.Count; i++) Revocation(chain[i], chain[i + 1], transport, dss, entry);
            }
            dss.Signature(contents.AsSpan(0, length).ToArray(), entry, time);
        }
        dss.Save();
    }

    // The certificates that vouch for a signature: its signer, and the authority of an embedded time stamp or a document time stamp.
    private static List<X509Certificate2> Subjects(byte[] contents, out List<X509Certificate2> pool, out int length)
    {
        var subjects = new List<X509Certificate2>();
        pool = [];
        length = 0;
        if (CmsSignature.Parse(contents) is { } cms)
        {
            length = cms.Length;
            pool.AddRange(cms.Certificates);
            if (cms.FindSigner() is { } signer) subjects.Add(signer);
            if (cms.UnsignedAttributes.TryGetValue(Oids.TimestampToken, out var tokens)) AddToken(tokens[0], subjects, pool);
        }
        else
        {
            AddToken(contents, subjects, pool);
            length = contents.Length;
            if (Rfc3161TimestampToken.TryDecode(contents, out _, out int consumed)) length = consumed;
        }
        return subjects;
    }

    private static void AddToken(byte[] encoded, List<X509Certificate2> subjects, List<X509Certificate2> pool)
    {
        if (!Rfc3161TimestampToken.TryDecode(encoded, out var token, out _) || token is null) return;
        var certificates = token.AsSignedCms().Certificates.Cast<X509Certificate2>().ToList();
        pool.AddRange(certificates);
        if (token.AsSignedCms().SignerInfos.Count > 0 && token.AsSignedCms().SignerInfos[0].Certificate is { } tsa) subjects.Add(tsa);
    }

    // The chain from the certificate up, with issuers fetched from the certificate's own links when the pool lacks them.
    private static List<X509Certificate2> BuildChain(X509Certificate2 leaf, List<X509Certificate2> pool, ISignatureTransport transport)
    {
        var chainCertificates = new List<X509Certificate2>();
        for (int round = 0; round < MaxChain; round++)
        {
            using var chain = new X509Chain();
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.DisableCertificateDownloads = true;
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority | X509VerificationFlags.IgnoreNotTimeValid;
            foreach (var c in pool) chain.ChainPolicy.ExtraStore.Add(c);
            chain.Build(leaf);
            chainCertificates = [.. chain.ChainElements.Select(e => X509CertificateLoader.LoadCertificate(e.Certificate.RawData))];
            var last = chainCertificates[^1];
            if (last.SubjectName.RawData.AsSpan().SequenceEqual(last.IssuerName.RawData)) break;
            var issuer = CertificateLinks.FetchIssuer(last, transport);
            if (issuer is null || pool.Any(c => c.Thumbprint == issuer.Thumbprint)) break;
            pool.Add(issuer);
        }
        return chainCertificates;
    }

    private static void Revocation(X509Certificate2 certificate, X509Certificate2 issuer, ISignatureTransport transport, DssWriter dss, DssWriter.Entry entry)
    {
        foreach (string url in CertificateLinks.OcspUrls(certificate))
        {
            byte[]? answer = transport.Post(url, "application/ocsp-request", OcspResponse.BuildRequest(certificate, issuer));
            if (answer is not null && OcspResponse.Parse(answer) is { } ocsp && ocsp.About(certificate, issuer).State != RevocationState.NoData)
            {
                entry.Ocsps.Add(dss.Ocsp(answer));
                return;
            }
        }
        foreach (string url in CertificateLinks.CrlUrls(certificate))
        {
            if (transport.Get(url) is { } bytes && Crl.Parse(bytes) is { } crl && crl.About(certificate, issuer).State != RevocationState.NoData)
            {
                entry.Crls.Add(dss.Crl(bytes));
                return;
            }
        }
    }
}

public enum ValidationServerKind { Ocsp, Crl, CaIssuers }

/// <summary>A server that adding validation data would contact; <paramref name="Host"/> is lower case.</summary>
public sealed record ValidationServer(ValidationServerKind Kind, string Url, string Host);
