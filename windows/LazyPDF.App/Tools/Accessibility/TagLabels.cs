using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>How an element of the tag tree reads in the tree view.</summary>
internal static class TagLabels
{
    public static string Of(StructElement element, StructureTree tree)
    {
        string standard = tree.StandardType(element.Type);
        string name = standard == element.Type || standard.Length == 0 ? element.Type : element.Type + " (" + standard + ")";
        if (name.Length == 0) name = Loc.T("Untitled tag");
        string note = Note(element);
        int page = FigureFinder.PageOf(element);
        string where = page >= 0 ? Loc.T(", page {0}", page + 1) : "";
        return note.Length > 0 ? name + where + ": " + note : name + where;
    }

    private static string Note(StructElement element)
    {
        foreach (string? text in new[] { element.Alt, element.ActualText, element.Title })
        {
            if (!string.IsNullOrWhiteSpace(text)) return text.Trim().Length > 60 ? text.Trim()[..60] + "..." : text.Trim();
        }
        return "";
    }
}

/// <summary>The lines of the reading order, and what a voice should say for each.</summary>
internal static class ReadingLines
{
    public static IReadOnlyList<string> Of(string order) =>
        order.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    /// <summary>The line without the marks that only show structure: heading hashes, figure brackets, tabs between cells.</summary>
    public static string Spoken(string line)
    {
        string text = line.TrimStart('#').Trim();
        if (text.StartsWith('[') && text.EndsWith(']')) text = text[1..^1];
        return text.Replace('\t', ',');
    }
}
