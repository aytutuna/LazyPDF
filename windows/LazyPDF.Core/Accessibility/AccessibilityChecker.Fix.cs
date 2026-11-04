namespace LazyPDF.Core;

public static partial class AccessibilityChecker
{
    /// <summary>
    /// Makes the repair a <see cref="AccessibilityItem"/> offers and returns whether anything changed.
    /// <see cref="AccessibilityFix.SetTitle"/> takes the title and <see cref="AccessibilityFix.SetLanguage"/>
    /// a language tag as <paramref name="value"/>; a missing or invalid one is an <see cref="ArgumentException"/>.
    /// The caller commits the document.
    /// </summary>
    public static bool Fix(PdfDocument document, AccessibilityFix fix, string? value = null)
    {
        switch (fix)
        {
            case AccessibilityFix.SetTitle:
                if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("A title is needed.", nameof(value));
                (DocumentMetadata.Read(document) with { Title = value.Trim() }).Write(document);
                ShowTitle(document);
                return true;
            case AccessibilityFix.ShowTitle:
                return !string.IsNullOrWhiteSpace(DocumentMetadata.Read(document).Title) && ShowTitle(document);
            case AccessibilityFix.SetLanguage:
                if (value is null || !LanguageTagPattern.IsMatch(value)) throw new ArgumentException("A language tag such as en-US is needed.", nameof(value));
                (ViewerSettings.Read(document) with { Language = value }).Write(document);
                return true;
            case AccessibilityFix.SetTabOrder:
                bool changed = false;
                foreach (var page in document.Pages)
                {
                    if (document.Array(page.Dictionary, "Annots") is not { Items.Count: > 0 } || document.Name(page.Dictionary, "Tabs") == "S") continue;
                    page.Dictionary["Tabs"] = new PdfName("S");
                    changed = true;
                }
                return changed;
            default:
                return false;
        }
    }

    private static bool ShowTitle(PdfDocument document)
    {
        var settings = ViewerSettings.Read(document);
        if (settings.DisplayDocTitle) return false;
        (settings with { DisplayDocTitle = true }).Write(document);
        return true;
    }
}
