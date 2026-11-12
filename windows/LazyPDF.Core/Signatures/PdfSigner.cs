using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// Applies signatures (ISO 32000-1 12.8, ETSI EN 319 142 PAdES) and document time stamps. A signature is
/// always an incremental update: the bytes of the file stay as they were, and the signature covers all of them.
/// Throws <see cref="InvalidOperationException"/> with a <see cref="SignatureText"/> message for what the user can
/// fix (a taken field, a missing key, a seed value that cannot be met) and <see cref="ArgumentException"/> for a bad page.
/// </summary>
public static class PdfSigner
{
    private const int BaseReserve = 4096;
    private const int TimestampReserve = 14000;

    /// <summary>The file with the signature added; the same bytes plus an update.</summary>
    public static byte[] Sign(byte[] pdf, PdfSignRequest request, string? password = null)
    {
        var job = new SignJob(request);
        byte[] file = SignOnce(PdfDocument.Open(pdf, password), job);
        if (job.Level >= PadesLevel.LT)
        {
            var document = PdfDocument.Open(file, password);
            PdfLongTermValidation.Add(document, request.Timestamp!.Transport, request.Time);
            file = document.SaveIncremental();
        }
        if (job.Level == PadesLevel.LTA) file = DocumentTimestamp(PdfDocument.Open(file, password), request.Timestamp!, request.Time);
        return file;
    }

    /// <summary>Signs the session's file: one step for the signature, one more for each of the validation data and the time stamp that the level adds.</summary>
    public static void Sign(PdfEditSession session, PdfSignRequest request)
    {
        var job = new SignJob(request);
        session.CommitBytes(Loc.T("Sign"), SignOnce(session.Document, job));
        if (job.Level >= PadesLevel.LT)
        {
            PdfLongTermValidation.Add(session.Document, request.Timestamp!.Transport, request.Time);
            session.Commit(Loc.T("Validation data"));
        }
        if (job.Level == PadesLevel.LTA) session.CommitBytes(Loc.T("Time stamp"), DocumentTimestamp(session.Document, request.Timestamp!, request.Time));
    }

    /// <summary>Adds a document time stamp (ETSI.RFC3161) over the whole file, which keeps earlier signatures and validation data verifiable once their certificates expire.</summary>
    public static byte[] AddDocumentTimestamp(byte[] pdf, TimestampSettings settings, DateTimeOffset time, string? password = null) =>
        DocumentTimestamp(PdfDocument.Open(pdf, password), settings, time);

    public static void AddDocumentTimestamp(PdfEditSession session, TimestampSettings settings, DateTimeOffset time) =>
        session.CommitBytes(Loc.T("Time stamp"), DocumentTimestamp(session.Document, settings, time));

    internal static byte[] SourceBytes(PdfDocument document) =>
        MemoryMarshal.TryGetArray(document.Source, out var segment) && segment.Offset == 0 && segment.Count == segment.Array!.Length
            ? segment.Array
            : document.Source.ToArray();

    private static byte[] SignOnce(PdfDocument document, SignJob job)
    {
        var request = job.Request;
        if (request.Signer is null && !request.Certificate.HasPrivateKey) throw new InvalidOperationException(SignatureText.NoPrivateKey);
        Oids.Digest(request.Digest);

        var target = SignatureField.Resolve(document, job);
        if (SignatureField.Refusal(document, target) is { } refusal) throw new InvalidOperationException(refusal);
        if (job.Certify != CertificationLevel.None && SignatureField.Attached(document).Count > 0) throw new InvalidOperationException(SignatureText.NotCertifiable);
        if (job.Level >= PadesLevel.T && request.Timestamp is null) throw new InvalidOperationException(SignatureText.NoTimestampServer);
        string? url = job.TimestampUrl;
        if (request.Timestamp is not null && url is null) throw new InvalidOperationException(SignatureText.NoTimestampServer);
        Oids.Digest(job.Digest);

        bool visible = !target.Rect.IsEmpty;
        var look = request.Look ?? new SignatureLook();
        string text = visible ? SignatureAppearance.Text(job, look) : "";
        var font = visible ? SignatureAppearance.AddFont(document, job, look, text) : null;
        var appearance = visible ? SignatureAppearance.Draw(document, target.Rect, target.Page.Rotate, look, text, font) : null;

        var chain = EmbeddedChain(request);
        int reserve = request.ReserveBytes > 0
            ? request.ReserveBytes
            : BaseReserve + request.Certificate.RawData.Length + chain.Sum(c => c.RawData.Length) + (request.Timestamp is null ? 0 : TimestampReserve);
        var contents = new PdfString(new byte[reserve], isHex: true);
        string subFilter = job.Format == SignatureFormat.CadesDetached ? "ETSI.CAdES.detached" : "adbe.pkcs7.detached";
        var signature = document.Add(SignatureField.Dictionary(document, job, contents, subFilter));
        if (target.IsNew && job.Lock is { } fieldLock) SignatureField.WriteLock(target.Field, fieldLock);
        SignatureField.Attach(document, target, signature, appearance);
        if (job.Certify != CertificationLevel.None) SignatureField.Certify(document, signature);

        var settings = new CmsSettings(request.Certificate, chain, job.Digest, job.Format == SignatureFormat.CadesDetached, request.Time, request.Signer);
        Func<byte[], byte[]?>? stamp = request.Timestamp is { } s ? value => TimestampClient.Request(s, url!, value) : null;
        return SignedUpdate.Build(document, contents, job.Digest, digest => CmsBuilder.Build(digest, settings, stamp));
    }

    private static byte[] DocumentTimestamp(PdfDocument document, TimestampSettings settings, DateTimeOffset time)
    {
        string url = settings.Url ?? throw new InvalidOperationException(SignatureText.NoTimestampServer);
        var form = PdfForm.Read(document);
        string name = SignatureField.Unique(form, "Timestamp");
        var field = new PdfDictionary();
        var page = document.Pages.Count > 0 ? document.Pages[0] : throw new ArgumentException(SignatureText.NoPage);
        var target = new SignatureField.Target(field, null, field, default, page, true, false, name);

        var contents = new PdfString(new byte[TimestampReserve], isHex: true);
        var dictionary = new PdfDictionary
        {
            ["Type"] = new PdfName("DocTimeStamp"),
            ["Filter"] = new PdfName("Adobe.PPKLite"),
            ["SubFilter"] = new PdfName("ETSI.RFC3161"),
            ["ByteRange"] = SignedUpdate.ByteRangePlaceholder(),
            ["Contents"] = contents,
        };
        var signature = document.Add(dictionary);
        SignatureField.Attach(document, target, signature, null);
        return SignedUpdate.Build(document, contents, settings.Digest, digest => TimestampClient.Request(settings, url, digest, hashed: true));
    }

    private static IReadOnlyList<X509Certificate2> EmbeddedChain(PdfSignRequest request)
    {
        if (request.Chain.Count > 0) return request.Chain;
        using var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.DisableCertificateDownloads = true;
        chain.Build(request.Certificate);
        return [.. chain.ChainElements.Skip(1).Select(e => e.Certificate).Where(c => !c.SubjectName.RawData.AsSpan().SequenceEqual(c.IssuerName.RawData))];
    }
}
