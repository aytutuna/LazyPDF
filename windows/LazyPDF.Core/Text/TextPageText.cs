namespace LazyPDF.Core;

/// <summary>The words of the problems the text layer reports.</summary>
public static class TextPageText
{
    public static string AnnotationsIncluded => Loc.T("This text includes annotation text, which the page's content does not hold. Build the page without IncludeAnnotations to edit or redact it.");
}
