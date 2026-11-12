namespace LazyPDF.App.Tools.Create;

internal static class WordNotice
{
    /// <summary>The note under a PDF made from a Word file: it can differ from Word, and what was left out.</summary>
    public static string Text(MadePdf made)
    {
        var left = (made.Features ?? []).OrderBy(s => s.Kind, StringComparer.Ordinal).Select(s => Name(s.Kind)).ToList();
        if (made.Unreadable > 0) left.Add(Loc.T("letters no font has"));
        string text = Loc.T("Layout can differ from Word.");
        return left.Count == 0 ? text : text + " " + Loc.T("Left out: {0}.", string.Join(", ", left));
    }

    private static string Name(string kind) => kind switch
    {
        "table" => Loc.T("tables too large or nested (shown as paragraphs)"),
        "text-box" => Loc.T("text boxes"),
        "picture" => Loc.T("pictures that could not be read"),
        "chart" => Loc.T("charts"),
        "shape" => Loc.T("shapes"),
        "drawing" => Loc.T("drawings"),
        "footnote" => Loc.T("footnotes"),
        "endnote" => Loc.T("endnotes"),
        "comment" => Loc.T("comment marks"),
        "equation" => Loc.T("equations"),
        "tracked-change" => Loc.T("tracked changes"),
        "field" => Loc.T("fields (shown as last saved)"),
        "floating-picture" => Loc.T("picture positions (placed in line)"),
        "rtl-text" => Loc.T("right-to-left text direction"),
        "complex-script" => Loc.T("complex-script shaping"),
        _ => kind,
    };
}
