using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <summary>The kinds of difference the filters switch on and off.</summary>
[Flags]
internal enum Parts
{
    Text = 1,
    Pictures = 2,
    Annotations = 4,
    Forms = 8,
    Pages = 16,
    Details = 32,
    All = 63,
}

internal static class ChangeParts
{
    // Core words a form field change as "Form field {0}"; cutting at a marker finds it in any language.
    private static readonly string[] FormWords = CompareText.FormField("\u0001").Split('\u0001');

    public static Parts Of(CompareChange change) => change.Area switch
    {
        ChangeArea.Text or ChangeArea.Format => Parts.Text,
        ChangeArea.Image => Parts.Pictures,
        ChangeArea.Annotation => Parts.Annotations,
        ChangeArea.Page => Parts.Pages,
        _ => change.Detail is { } detail && detail.StartsWith(FormWords[0], StringComparison.Ordinal) && detail.EndsWith(FormWords[1], StringComparison.Ordinal)
            ? Parts.Forms : Parts.Details,
    };

    /// <summary>The result with only the changes of <paramref name="parts"/>, and the counts of those.</summary>
    public static ComparisonResult Only(ComparisonResult result, Parts parts)
    {
        if (parts == Parts.All) return result;
        var kept = result.Changes.Where(c => parts.HasFlag(Of(c))).ToList();
        int Kind(ChangeKind k) => kept.Count(c => c.Kind == k);
        int Area(ChangeArea a) => kept.Count(c => c.Area == a);
        var summary = result.Summary with
        {
            Added = Kind(ChangeKind.Added),
            Removed = Kind(ChangeKind.Removed),
            Changed = Kind(ChangeKind.Changed),
            Moved = Kind(ChangeKind.Moved),
            Text = Area(ChangeArea.Text),
            Format = Area(ChangeArea.Format),
            Images = Area(ChangeArea.Image),
            Annotations = Area(ChangeArea.Annotation),
            Pages = Area(ChangeArea.Page),
            Document = Area(ChangeArea.Document),
        };
        // The report lists removed pages from Pages, not from the changes.
        var pages = parts.HasFlag(Parts.Pages) ? result.Pages : [.. result.Pages.Where(p => !p.IsRemoved)];
        return result with { Pages = pages, Changes = kept, Summary = summary };
    }
}
