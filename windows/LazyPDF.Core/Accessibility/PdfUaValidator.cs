namespace LazyPDF.Core;

/// <summary>
/// The machine-checkable failure conditions of the Matterhorn Protocol 1.1 for ISO 14289-1 (PDF/UA-1). What needs a person
/// (reading order, whether alt text says the right thing, contrast) is not here; <see cref="AccessibilityChecker"/> lists
/// those for the user.
/// </summary>
public static class PdfUaValidator
{
    public static PdfUaReport Validate(PdfDocument document, CancellationToken cancel = default)
    {
        var checker = new PdfUaChecker(document, cancel);
        checker.Run();
        return checker.Report();
    }
}
