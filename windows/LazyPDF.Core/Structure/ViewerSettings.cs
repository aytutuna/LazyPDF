namespace LazyPDF.Core;

/// <summary>What the viewer shows beside the page when the file opens (/PageMode).</summary>
public enum PageMode { UseNone, UseOutlines, UseThumbs, FullScreen, UseOC, UseAttachments }

/// <summary>How the pages are laid out when the file opens (/PageLayout).</summary>
public enum PageLayout { SinglePage, OneColumn, TwoColumnLeft, TwoColumnRight, TwoPageLeft, TwoPageRight }

/// <summary>
/// The catalog entries that say how a file opens (ISO 32000-1 7.7.2, 12.2): language, page mode and
/// layout, and the /ViewerPreferences. <see cref="Duplex"/> is Simplex, DuplexFlipShortEdge or
/// DuplexFlipLongEdge; <see cref="NumCopies"/> is 2 to 5 or null.
/// </summary>
public sealed record ViewerSettings(
    string? Language, bool DisplayDocTitle, PageMode PageMode, PageLayout PageLayout, bool HideToolbar, bool HideMenubar,
    bool HideWindowUI, bool FitWindow, bool CenterWindow, bool RightToLeft, bool PrintScalingNone, string? Duplex, int? NumCopies)
{
    public static ViewerSettings Read(PdfDocument document)
    {
        var catalog = document.Catalog;
        var prefs = document.Dict(catalog, "ViewerPreferences");
        bool Flag(string key) => document.Bool(prefs, key) == true;
        return new ViewerSettings(
            PdfText.Read(document, catalog, "Lang"), Flag("DisplayDocTitle"),
            Enum.TryParse(document.Name(catalog, "PageMode"), out PageMode mode) ? mode : PageMode.UseNone,
            Enum.TryParse(document.Name(catalog, "PageLayout"), out PageLayout layout) ? layout : PageLayout.SinglePage,
            Flag("HideToolbar"), Flag("HideMenubar"), Flag("HideWindowUI"), Flag("FitWindow"), Flag("CenterWindow"),
            document.Name(prefs, "Direction") == "R2L", document.Name(prefs, "PrintScaling") == "None",
            document.Name(prefs, "Duplex"), document.Integer(prefs, "NumCopies") is >= 2 and <= 5 and var copies ? (int)copies : null);
    }

    /// <summary>
    /// Stores the settings. A value that is the default is taken out rather than written, and keys
    /// of /ViewerPreferences not listed here stay.
    /// </summary>
    public void Write(PdfDocument document)
    {
        var catalog = document.Catalog;
        if (string.IsNullOrEmpty(Language)) catalog.Remove("Lang");
        else catalog["Lang"] = PdfText.ToObject(Language);
        SetName(catalog, "PageMode", PageMode == PageMode.UseNone ? null : PageMode.ToString());
        SetName(catalog, "PageLayout", PageLayout == PageLayout.SinglePage ? null : PageLayout.ToString());

        var prefs = document.Dict(catalog, "ViewerPreferences") ?? new PdfDictionary();
        void Flag(string key, bool on)
        {
            if (on) prefs[key] = new PdfBoolean(true);
            else prefs.Remove(key);
        }
        Flag("DisplayDocTitle", DisplayDocTitle);
        Flag("HideToolbar", HideToolbar);
        Flag("HideMenubar", HideMenubar);
        Flag("HideWindowUI", HideWindowUI);
        Flag("FitWindow", FitWindow);
        Flag("CenterWindow", CenterWindow);
        SetName(prefs, "Direction", RightToLeft ? "R2L" : null);
        SetName(prefs, "PrintScaling", PrintScalingNone ? "None" : null);
        SetName(prefs, "Duplex", Duplex);
        if (NumCopies is >= 2 and <= 5) prefs["NumCopies"] = new PdfNumber(NumCopies.Value);
        else prefs.Remove("NumCopies");

        if (prefs.Count == 0) catalog.Remove("ViewerPreferences");
        else if (document.Dict(catalog, "ViewerPreferences") is null) catalog["ViewerPreferences"] = prefs;
    }

    private static void SetName(PdfDictionary dictionary, string key, string? value)
    {
        if (value is null) dictionary.Remove(key);
        else dictionary[key] = new PdfName(value);
    }
}
