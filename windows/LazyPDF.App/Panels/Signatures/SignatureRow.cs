using System.Security.Cryptography.X509Certificates;
using System.Windows;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Signatures;

public enum SignatureLevel
{
    Good,
    Caution,
    Bad,
    Unknown,
}

/// <summary>A heading and the plain lines under it, in the details of one signature.</summary>
public sealed record SignatureSection(string Heading, IReadOnlyList<string> Lines);

/// <summary>One signature in the list, in the words Core has for it.</summary>
public sealed class SignatureRow(SignatureReport report, int page, Rect where)
{
    public SignatureReport Report { get; } = report;

    /// <summary>The page the signature's field is on, or -1 when it has none.</summary>
    public int Page { get; } = page;

    /// <summary>The field on that page, in page space.</summary>
    public Rect Where { get; } = where;

    public string Title => Report.SignerName ?? Report.FieldName ?? Loc.T("Signature {0}", Report.Index + 1);

    public string Status => Flaw is { } flaw ? SignatureText.Title(flaw) : SignatureText.Status(Report.Verdict);

    public string Sentence => Flaw is { } flaw ? SignatureText.Title(flaw) + ". " + SignatureText.Advice(flaw) : Report.Sentence;

    public string Caveat => Level == SignatureLevel.Good && NotChecked().Count > 0 ? Loc.T("Not everything could be checked. See the details.") : "";

    public Visibility CaveatVisibility => Caveat.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

    public string Summary => Title + ", " + Status + ". " + Sentence + (Caveat.Length == 0 ? "" : " " + Caveat);

    public SignatureLevel Level => Report.Verdict switch
    {
        SignatureVerdict.Valid => SignatureLevel.Good,
        SignatureVerdict.ValidButUntrusted => Flaw == SignatureProblem.CertificateRevoked ? SignatureLevel.Bad : SignatureLevel.Caution,
        SignatureVerdict.ChangedAfterSigning or SignatureVerdict.Broken => SignatureLevel.Bad,
        _ => SignatureLevel.Unknown,
    };

    public string Glyph => Level switch
    {
        SignatureLevel.Good => "\uE73E",
        SignatureLevel.Caution => "\uE7BA",
        SignatureLevel.Bad => "\uEA39",
        _ => "\uE946",
    };

    /// <summary>Whether the open file goes on past this signature, so that its signed version differs from it.</summary>
    public bool HasLaterRevisions => Report.Revision > 0 && !Report.CoversWholeFile;

    // A signer that is only unknown reads as such. One whose certificate was withdrawn, or that has some other flaw, reads as that.
    private SignatureProblem? Flaw
    {
        get
        {
            if (Report.Verdict != SignatureVerdict.ValidButUntrusted) return null;
            if (Report.Problems.Contains(SignatureProblem.CertificateRevoked)) return SignatureProblem.CertificateRevoked;
            foreach (var problem in Report.Problems)
            {
                if (problem != SignatureProblem.UntrustedSigner) return problem;
            }
            return null;
        }
    }

    /// <summary>What is known about the signature, then what changed since, what is wrong, and what could not be checked.</summary>
    public IReadOnlyList<SignatureSection> Sections
    {
        get
        {
            var sections = new List<SignatureSection>
            {
                new(Loc.T("About the signature"), Facts()),
                new(Loc.T("Changed since signing"), Changes()),
                new(Loc.T("Problems"), Problems()),
                new(Loc.T("Not checked"), NotChecked()),
            };
            return [.. sections.Where(s => s.Lines.Count > 0)];
        }
    }

    private List<string> Facts()
    {
        var lines = new List<string>();
        if (Report.Certificate?.GetNameInfo(X509NameType.SimpleName, true) is { Length: > 0 } issuer) lines.Add(Loc.T("Certificate from {0}.", issuer));
        if (!string.IsNullOrWhiteSpace(Report.Reason)) lines.Add(Loc.T("Reason: {0}", Report.Reason));
        if (!string.IsNullOrWhiteSpace(Report.Location)) lines.Add(Loc.T("Place: {0}", Report.Location));
        if (Report.Kind == SignatureKind.Certification)
        {
            lines.AddRange(Report.Certification switch
            {
                CertificationLevel.NoChanges => [Loc.T("Certified: no changes are allowed.")],
                CertificationLevel.FormFill => [Loc.T("Certified: form filling is allowed.")],
                CertificationLevel.Annotate => [Loc.T("Certified: form filling and comments are allowed.")],
                _ => Array.Empty<string>(),
            });
        }
        if (Report.Level >= PadesLevel.LT) lines.Add(Loc.T("Proof of the certificate is stored in the file."));
        return lines;
    }

    private List<string> Changes() =>
        [.. Report.Changes.Changes.Select(c => c.Allowed ? SignatureText.Describe(c) : Loc.T("{0}, not allowed", SignatureText.Describe(c))).Distinct()];

    private List<string> Problems() =>
        [.. Report.Problems.Select(p => SignatureText.Title(p) + ". " + SignatureText.Advice(p))];

    private List<string> NotChecked()
    {
        var lines = new List<string>();
        if (Report.Verdict == SignatureVerdict.Unknown) return lines;
        if (Report.Certificate is not null && !Report.RevocationChecked) lines.Add(Loc.T("Whether the certificate was withdrawn."));
        if (Report.Kind != SignatureKind.DocumentTimestamp && Report.TimestampTime is null) lines.Add(Loc.T("When it was signed. The time is the signer's word."));
        return lines;
    }
}
