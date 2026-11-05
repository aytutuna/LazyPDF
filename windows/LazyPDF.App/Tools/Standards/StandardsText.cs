using LazyPDF.Core;

namespace LazyPDF.App.Tools.Standards;

/// <summary>The words of the PDF/A panel that are not Core's.</summary>
internal static class StandardsText
{
    public static string Describe(PdfALevel level) => level switch
    {
        PdfALevel.A1b => Loc.T("The oldest and strictest. No transparency."),
        PdfALevel.A2b => Loc.T("Allows transparency and layers. The usual choice."),
        PdfALevel.A2u => Loc.T("Like 2b, and every character keeps its text."),
        PdfALevel.A3b => Loc.T("Like 2b, and other files may be attached."),
        PdfALevel.A3u => Loc.T("Like 3b, and every character keeps its text."),
        _ => Loc.T("The newest, based on PDF 2.0."),
    };

    /// <summary>What converting costs this file, said before it is done.</summary>
    public static string Losses(bool signed, bool encrypted)
    {
        string signs = signed ? Loc.T("The file is signed. The new file loses the signatures.") : "";
        string password = encrypted ? Loc.T("The new file is not password protected.") : "";
        return (signs + " " + password).Trim();
    }

    public static string ConvertedTitle(PdfAConversion made) =>
        made.IsClean ? Loc.T("Converted, checks passed") : Loc.T("Converted, rules still broken");

    /// <summary>What was made, said with the checks' own words, then everything the conversion changed.</summary>
    public static string ConvertedText(PdfAConversion made, PdfALevel level)
    {
        string name = level.Name();
        int left = IssueRow.Group(made.Remaining).Count;
        string result = left == 0
            ? Loc.T("The new file passes Lazy PDF's checks for {0}.", name)
            : Loc.T("The new file still breaks {0} rules of {1}. The panel lists them.", left, name);
        return string.Join(" ", [result, .. made.Changes, Loc.T("It is open in a new tab. Save it to keep it.")]);
    }

    /// <summary>The name of the new tab: the file's, with the level where it passes. The level's slash is left out because a name is cut at it.</summary>
    public static string ConvertedName(string title, PdfALevel level, bool clean)
    {
        string mark = clean ? level.Name().Replace('/', '-') : Loc.T("converted");
        return Path.GetFileNameWithoutExtension(title) + " (" + mark + ").pdf";
    }
}
