namespace LazyPDF.Core;

/// <summary>
/// The machine-checkable failure conditions of the Matterhorn Protocol 1.1 for ISO 14289-1 (PDF/UA-1). What needs a person
/// (reading order, whether alt text says the right thing, contrast) is not here; <see cref="AccessibilityChecker"/> lists
/// those for the user. Nothing is changed except by <see cref="Mark"/>, which takes the date for the metadata.
/// </summary>
public static class PdfUaValidator
{
    // The conditions marking settles itself: the identifier, the title shown, and a packet made from /Info.
    private static readonly string[] SettledByMark = ["06-001", "06-002", "06-003", "07-001"];

    public static PdfUaReport Validate(PdfDocument document, CancellationToken cancel = default)
    {
        var checker = new PdfUaChecker(document, cancel);
        checker.Run();
        return checker.Report();
    }

    /// <summary>
    /// Writes pdfuaid:part 1 to the XMP (a packet is made when the file has none) and sets DisplayDocTitle, but only when
    /// nothing else fails. The caller commits the document.
    /// </summary>
    public static PdfUaMarkResult Mark(PdfDocument document, DateTimeOffset date, CancellationToken cancel = default)
    {
        var report = Validate(document, cancel);
        bool title = !string.IsNullOrWhiteSpace(DocumentMetadata.Read(document).Title);
        var blocking = report.Issues.Where(i => !SettledByMark.Contains(i.Condition) || (i.Condition is "06-003" && !title)).ToList();
        if (blocking.Count > 0 || report.Truncated) return new PdfUaMarkResult(false, new PdfUaReport(blocking, report.Truncated));
        if (!PdfUaMarker.Write(document, date)) return new PdfUaMarkResult(false, report);
        return new PdfUaMarkResult(true, new PdfUaReport([], false));
    }
}
