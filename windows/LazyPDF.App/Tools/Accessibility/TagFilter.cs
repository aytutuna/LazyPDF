using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>The elements of the tag tree whose type or text has the words typed in the filter box, with everything above them.</summary>
internal sealed record TagFilter(HashSet<StructElement> Shown, int Matches, bool IsCapped)
{
    public const int Limit = 500;

    public static TagFilter? Of(StructureTree tree, string text)
    {
        text = text.Trim();
        if (text.Length == 0) return null;
        var shown = new HashSet<StructElement>();
        int matches = 0;
        bool capped = false;
        foreach (var element in tree.Elements)
        {
            if (!Hit(tree, element, text)) continue;
            if (matches == Limit)
            {
                capped = true;
                break;
            }
            matches++;
            for (var p = element; p is not null && shown.Add(p); p = p.Parent) { }
        }
        return new TagFilter(shown, matches, capped);
    }

    private static bool Hit(StructureTree tree, StructElement element, string text) =>
        Has(element.Type, text) || Has(tree.StandardType(element.Type), text) || Has(element.Title, text) || Has(element.Alt, text)
        || Has(element.ActualText, text) || Has(element.Id, text);

    private static bool Has(string? value, string text) => value is not null && value.Contains(text, StringComparison.OrdinalIgnoreCase);
}
