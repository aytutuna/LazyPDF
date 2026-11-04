using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// Checks every signature in a file: the byte range, the digest, the CMS signature, the signer's certificate
/// and chain at the time of signing, an embedded time stamp, revocation data from the signature and /DSS, and what
/// changed after the signature. Reading never throws on file contents except <see cref="PdfReadException"/> from opening the file.
/// </summary>
public static class PdfSignatureVerifier
{
    public static IReadOnlyList<SignatureReport> Verify(byte[] pdf, VerifyOptions? options = null)
    {
        options ??= new VerifyOptions();
        var document = PdfDocument.Open(pdf, options.Password);
        var file = PdfSigner.SourceBytes(document);
        var found = SignatureScan.Find(file).OrderBy(f => f.Offset).ToList();
        var checker = new SignatureChecker(document, file, PdfRevisions.List(file), options, found);
        var reports = found.Select(checker.Check).ToList();
        for (int i = 0; i < reports.Count; i++)
        {
            // Long term validation archives data in the file; a time stamp over it, later, keeps that data trustworthy.
            if (reports[i].Level == PadesLevel.LT && reports.Skip(i + 1).Any(r => r.Kind == SignatureKind.DocumentTimestamp && r.Verdict is SignatureVerdict.Valid or SignatureVerdict.ValidButUntrusted))
            {
                reports[i] = reports[i] with { Level = PadesLevel.LTA };
            }
        }
        return reports;
    }

    public static IReadOnlyList<SignatureReport> Verify(PdfEditSession session, VerifyOptions? options = null) =>
        Verify(session.Current.ToArray(), options);
}

internal sealed class SignatureChecker
{
    private readonly PdfDocument _document;
    private readonly byte[] _file;
    private readonly IReadOnlyList<PdfRevision> _revisions;
    private readonly VerifyOptions _options;
    private readonly ValidationData _dss;
    private readonly HashSet<long> _signatures;
    private Dictionary<int, string>? _fieldNames;

    public SignatureChecker(PdfDocument document, byte[] file, IReadOnlyList<PdfRevision> revisions, VerifyOptions options, IReadOnlyList<FoundSignature> found)
    {
        _document = document;
        _file = file;
        _revisions = revisions;
        _options = options;
        _dss = ValidationData.ReadDss(document);
        _signatures = found.Where(f => SignedRanges.Check(file, f, revisions) is { } ranges && CmsSignature.Parse(ranges.Contents) is not null).Select(f => f.Offset).ToHashSet();
    }

    public SignatureReport Check(FoundSignature found, int index)
    {
        var dictionary = DictionaryOf(found);
        string subFilter = _document.Name(dictionary, "SubFilter") ?? "";
        bool stamp = _document.Name(dictionary, "Type") == "DocTimeStamp" || subFilter == "ETSI.RFC3161";
        var report = new SignatureReport
        {
            Index = index,
            FieldName = FieldNames().GetValueOrDefault(found.Number),
            Kind = stamp ? SignatureKind.DocumentTimestamp : SignatureKind.Approval,
            SubFilter = subFilter,
            SignerName = stamp ? null : PdfText.Read(_document, dictionary["Name"]),
            Reason = PdfText.Read(_document, dictionary["Reason"]),
            Location = PdfText.Read(_document, dictionary["Location"]),
            SigningTime = PdfDate.Parse(PdfText.Read(_document, dictionary["M"])),
        };

        var ranges = SignedRanges.Check(_file, found, _revisions);
        if (ranges is null) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadByteRange);
        report = report with
        {
            Revision = ranges.Revision.Number,
            CoversWholeFile = IsBlank(ranges.End, _file.Length),
        };

        var outcome = stamp ? CheckTimestamp(report, ranges) : CheckSignature(report, ranges, subFilter);
        return outcome.Verdict is SignatureVerdict.Broken or SignatureVerdict.Unknown ? outcome : WithChanges(outcome, ranges, found);
    }

    private SignatureReport CheckSignature(SignatureReport report, SignedRanges ranges, string subFilter)
    {
        if (subFilter is not ("adbe.pkcs7.detached" or "ETSI.CAdES.detached")) return Fail(report, SignatureVerdict.Unknown, SignatureProblem.UnsupportedFormat);
        var cms = CmsSignature.Parse(ranges.Contents);
        if (cms is null) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);
        if (ranges.Contents.AsSpan(cms.Length).ContainsAnyExcept((byte)0)) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);
        if (cms.FindSigner() is not { } signer) return Fail(report, SignatureVerdict.Unknown, SignatureProblem.NoCertificate);

        if (!cms.SigningCertificateMatches(signer)) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);

        var problems = new List<SignatureProblem>();
        var digests = new Dictionary<string, byte[]>();
        var check = CmsVerifier.Check(cms, signer, algorithm => digests.TryGetValue(algorithm.Name!, out var d) ? d : digests[algorithm.Name!] = ranges.Digest(_file, algorithm));
        switch (check)
        {
            case CmsCheck.DigestMismatch: return Fail(report, SignatureVerdict.Broken, SignatureProblem.DigestMismatch);
            case CmsCheck.BadSignature: return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);
            case CmsCheck.Unsupported: return Fail(report, SignatureVerdict.Unknown, SignatureProblem.UnsupportedFormat);
        }
        if (cms.DigestOid == "1.3.14.3.2.26") problems.Add(SignatureProblem.WeakDigest);

        var extra = cms.Certificates.Concat(_dss.Certificates).ToList();
        DateTimeOffset? stamped = null;
        if (cms.UnsignedAttributes.TryGetValue(Oids.TimestampToken, out var tokens) && tokens.Count > 0)
        {
            stamped = CheckToken(tokens[0], cms.Signature, extra, problems);
        }
        var signingTime = cms.SigningTime() ?? report.SigningTime;
        // The signer's own clock proves nothing; without a trusted time stamp the chain is judged now.
        var time = stamped ?? _options.Now;

        var trust = CertificateTrust.Evaluate(signer, extra, time, _options);
        if (!trust.Trusted) problems.Add(SignatureProblem.UntrustedSigner);
        if (!trust.TimeValid || stamped is null && signingTime is { } claimed && (claimed < signer.NotBefore || claimed > signer.NotAfter)) problems.Add(SignatureProblem.CertificateNotValid);

        var evidence = new ValidationData();
        evidence.ReadArchival(cms);
        evidence.Certificates.AddRange(_dss.Certificates);
        evidence.Ocsps.AddRange(_dss.Ocsps);
        evidence.Crls.AddRange(_dss.Crls);
        bool checkedAll = trust.Chain.Count > 1;
        for (int i = 0; i + 1 < trust.Chain.Count; i++)
        {
            var (state, at) = evidence.Check(trust.Chain[i], trust.Chain[i + 1], time);
            if (state == RevocationState.Revoked && (time is null || at is null || at <= time)) problems.Add(SignatureProblem.CertificateRevoked);
            checkedAll &= state == RevocationState.Good;
        }

        bool cades = report.SubFilter == "ETSI.CAdES.detached";
        var level = PadesLevel.None;
        if (cades && cms.Attributes.ContainsKey(Oids.SigningCertificateV2))
        {
            level = PadesLevel.B;
            if (stamped is not null && !problems.Contains(SignatureProblem.TimestampInvalid)) level = PadesLevel.T;
            if (level == PadesLevel.T && checkedAll) level = PadesLevel.LT;
        }

        return report with
        {
            Certificate = signer,
            SignerName = SignJob.CertificateName(signer) is { Length: > 0 } name ? name : report.SignerName,
            SigningTime = signingTime,
            TimestampTime = stamped,
            TimeUsed = time,
            Level = level,
            RevocationChecked = checkedAll,
            Problems = problems.Distinct().ToList(),
            Verdict = problems.Count == 0 ? SignatureVerdict.Valid : SignatureVerdict.ValidButUntrusted,
        };
    }

    private SignatureReport CheckTimestamp(SignatureReport report, SignedRanges ranges)
    {
        if (!Rfc3161TimestampToken.TryDecode(ranges.Contents, out var token, out int length) || token is null) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);
        if (ranges.Contents.AsSpan(length).ContainsAnyExcept((byte)0)) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);
        if (Oids.DigestName(token.TokenInfo.HashAlgorithmId.Value ?? "") is not { } algorithm) return Fail(report, SignatureVerdict.Unknown, SignatureProblem.UnsupportedFormat);
        byte[] hash = ranges.Digest(_file, algorithm);
        if (!token.TokenInfo.GetMessageHash().Span.SequenceEqual(hash)) return Fail(report, SignatureVerdict.Broken, SignatureProblem.DigestMismatch);
        var carried = TokenCertificates(token);
        var extra = new X509Certificate2Collection(_dss.Certificates.Concat(carried).ToArray());
        if (!token.VerifySignatureForHash(hash, algorithm, out var tsa, extra) || tsa is null) return Fail(report, SignatureVerdict.Broken, SignatureProblem.BadSignature);

        var problems = new List<SignatureProblem>();
        var time = token.TokenInfo.Timestamp;
        var trust = CertificateTrust.Evaluate(tsa, _dss.Certificates.Concat(carried), time, _options, timestamp: true);
        if (!trust.Trusted) problems.Add(SignatureProblem.UntrustedSigner);
        if (!trust.TimeValid) problems.Add(SignatureProblem.CertificateNotValid);
        return report with
        {
            Certificate = tsa,
            SigningTime = time,
            TimestampTime = time,
            TimeUsed = time,
            Problems = problems,
            Verdict = problems.Count == 0 ? SignatureVerdict.Valid : SignatureVerdict.ValidButUntrusted,
        };
    }

    private DateTimeOffset? CheckToken(byte[] encoded, byte[] signature, List<X509Certificate2> extra, List<SignatureProblem> problems)
    {
        if (!Rfc3161TimestampToken.TryDecode(encoded, out var token, out _) || token is null
            || Oids.DigestName(token.TokenInfo.HashAlgorithmId.Value ?? "") is not { } algorithm)
        {
            problems.Add(SignatureProblem.TimestampInvalid);
            return null;
        }
        byte[] hash = CmsBuilder.HashData(algorithm, signature);
        if (!token.VerifySignatureForHash(hash, algorithm, out var tsa, new X509Certificate2Collection(extra.ToArray())) || tsa is null)
        {
            problems.Add(SignatureProblem.TimestampInvalid);
            return null;
        }
        var time = token.TokenInfo.Timestamp;
        var trust = CertificateTrust.Evaluate(tsa, extra.Concat(TokenCertificates(token)), time, _options, timestamp: true);
        if (!trust.Trusted || !trust.TimeValid)
        {
            problems.Add(SignatureProblem.TimestampInvalid);
            return null;
        }
        return time;
    }

    private static IEnumerable<X509Certificate2> TokenCertificates(Rfc3161TimestampToken token) =>
        token.AsSignedCms().Certificates.Cast<X509Certificate2>();

    // The signature is intact; what is left is whether the file stayed as signed.
    private SignatureReport WithChanges(SignatureReport report, SignedRanges ranges, FoundSignature found)
    {
        int level = 0;
        var changes = SignatureChangeReport.None;
        var kind = report.Kind;
        if (!IsBlank(ranges.End, _file.Length))
        {
            PdfDocument signed;
            try
            {
                signed = PdfDocument.Open(_file.AsSpan(0, ranges.End).ToArray(), _options.Password);
            }
            catch (PdfReadException)
            {
                return Fail(report, SignatureVerdict.Unknown, SignatureProblem.DamagedStructure);
            }
            if (signed.XrefRebuilt) return Fail(report, SignatureVerdict.Unknown, SignatureProblem.DamagedStructure);
            (level, bool certification) = Level(signed, found.Number);
            if (certification && kind == SignatureKind.Approval) kind = SignatureKind.Certification;
            int later = _revisions.Count(r => r.End > ranges.Revision.End);
            changes = ChangeDetector.Compare(signed, _document, level, _signatures) with { RevisionsAfter = later };
        }
        else if (kind == SignatureKind.Approval)
        {
            (level, bool certification) = Level(_document, found.Number);
            if (certification) kind = SignatureKind.Certification;
        }

        var problems = report.Problems.ToList();
        var verdict = report.Verdict;
        if (!changes.AllAllowed)
        {
            problems.Add(SignatureProblem.ChangedAfterSigning);
            verdict = SignatureVerdict.ChangedAfterSigning;
        }
        return report with { Kind = kind, Certification = (CertificationLevel)level, Changes = changes, Problems = problems, Verdict = verdict };
    }

    // The access permission in force for a signature: 0 for a file that is not certified.
    internal static (int Level, bool Certification) Level(PdfDocument document, int signatureNumber)
    {
        if (document.Dict(document.Catalog, "Perms") is not { } perms || perms["DocMDP"] is not PdfReference reference) return (0, false);
        if (document.Resolve(reference) is not PdfDictionary signature) return (0, false);
        int level = 2;
        if (document.Array(signature, "Reference") is { } references)
        {
            foreach (var item in references.Items)
            {
                if (document.Resolve(item) is PdfDictionary r && document.Name(r, "TransformMethod") == "DocMDP"
                    && document.Dict(r, "TransformParams") is { } parameters && document.Integer(parameters, "P") is { } p)
                {
                    level = (int)Math.Clamp(p, 1, 3);
                }
            }
        }
        return (level, reference.Number == signatureNumber);
    }

    private static SignatureReport Fail(SignatureReport report, SignatureVerdict verdict, SignatureProblem problem) =>
        report with { Verdict = verdict, Problems = [problem] };

    // At most one end-of-line follows the last %%EOF; any more is a tail for the change rules to read, whatever it holds.
    private bool IsBlank(int from, int to) => _file.AsSpan(from, to - from) is [] or [(byte)'\n'] or [(byte)'\r'] or [(byte)'\r', (byte)'\n'];

    // The final file's own copy of the signature object when it is the one in the bytes: decrypted, with references usable.
    private PdfDictionary DictionaryOf(FoundSignature found) =>
        _document.Entries.TryGetValue(found.Number, out var entry) && entry.Kind == PdfDocument.EntryKind.InUse && entry.Offset == found.Offset
        && _document.Get(found.Number) is PdfDictionary current
            ? current
            : found.Dictionary;

    private Dictionary<int, string> FieldNames()
    {
        if (_fieldNames is not null) return _fieldNames;
        _fieldNames = [];
        foreach (var field in PdfForm.Read(_document).Fields)
        {
            if (field.Kind == FieldKind.Signature && field.Dictionary["V"] is PdfReference r) _fieldNames.TryAdd(r.Number, field.Name);
        }
        return _fieldNames;
    }
}
