using LazyPDF.Core;

namespace LazyPDF.App.Tools.PdfUa;

/// <summary>What the PDF/UA check found, and whether marking the file would be accepted.</summary>
internal sealed record UaOutcome(PdfUaReport Report, bool CanMark)
{
    /// <summary>
    /// Runs the check on a private copy. Marking is tried on the same copy, so the offer to mark is made only when it would
    /// work and the tab's file is not touched.
    /// </summary>
    public static UaOutcome Of(PdfDocument copy, CancellationToken token)
    {
        var report = PdfUaValidator.Validate(copy, token);
        bool canMark = !report.IsValid && !report.Truncated && PdfUaValidator.Mark(copy, DateTimeOffset.Now, token).Marked;
        return new UaOutcome(report, canMark);
    }

    public string Verdict(int rows) => Report.IsValid
        ? Loc.T("Passes Lazy PDF's checks for PDF/UA-1.")
        : Loc.T("Does not pass the checks for PDF/UA-1. Conditions broken: {0}.", rows);

    public string Status => Report.IsValid ? Loc.T("Passes Lazy PDF's PDF/UA-1 checks.") : Loc.T("Fails PDF/UA-1 checks.");
}
