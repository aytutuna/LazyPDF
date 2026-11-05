using System.Windows;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <summary>
/// One line of the change list. Boxes are in page space (points as shown, y down) of the page on their side; a
/// side the change does not touch has none. <see cref="Kind"/> is null for a region found by the pixel comparison.
/// </summary>
internal sealed record ChangeRow(ChangeKind? Kind, string Title, string Subtitle, int OldPage, int NewPage, IReadOnlyList<Rect> OldBoxes, IReadOnlyList<Rect> NewBoxes)
{
    private const int MaxBoxes = 200;
    private const int MaxTitle = 70;

    public string Spoken => Title + ", " + Subtitle;

    public Rect? OldArea => Union(OldBoxes);

    public Rect? NewArea => Union(NewBoxes);

    public static ChangeRow Of(CompareChange change, PdfDocument before, PdfDocument after)
    {
        string title = change.Area == ChangeArea.Text ? TextTitle(change) : change.Detail ?? CompareText.AreaName(change.Area);
        string[] parts = [CompareText.KindName(change.Kind), Where(change.OldPage, change.NewPage), change.Area == ChangeArea.Document ? Values(change) : ""];
        return new ChangeRow(change.Kind, title, string.Join(" · ", parts.Where(p => p.Length > 0)), change.OldPage, change.NewPage,
            Boxes(before, change.OldPage, change.OldQuads), Boxes(after, change.NewPage, change.NewQuads));
    }

    /// <summary>The region is in the new page's points; the old page's box is found by undoing what the comparer did to the old page.</summary>
    public static ChangeRow Of(PagePair pair, PixelDifference difference, PixelAlignment alignment, double dpi, PageGeometry before, PageGeometry after)
    {
        var box = new Rect(difference.Region.X, difference.Region.Y, difference.Region.Width, difference.Region.Height);
        int down = after.Height > 0 ? (int)Math.Round(Math.Clamp(box.Y / after.Height, 0, 1) * 100) : 0;
        return new ChangeRow(null, Loc.T("Looks different"), Loc.T("Page {0}, {1} % down", pair.NewIndex + 1, down), pair.OldIndex, pair.NewIndex,
            [OldBox(box, alignment, dpi, before, after)], [box]);
    }

    // The old page was resized to the new one, then turned about its centre and shifted; the mapping mirrors PixelAligner's.
    internal static Rect OldBox(Rect box, PixelAlignment alignment, double dpi, PageGeometry before, PageGeometry after)
    {
        double toPoints = 72 / dpi, radians = alignment.Degrees * Math.PI / 180;
        double cos = Math.Cos(radians), sin = Math.Sin(radians), cx = after.Width / 2, cy = after.Height / 2;
        var found = Rect.Empty;
        foreach (var (x, y) in new[] { (box.Left, box.Top), (box.Right, box.Top), (box.Left, box.Bottom), (box.Right, box.Bottom) })
        {
            double px = x - cx - alignment.ShiftX * toPoints, py = y - cy - alignment.ShiftY * toPoints;
            found.Union(new Point((cos * px + sin * py + cx) * before.Width / after.Width, (-sin * px + cos * py + cy) * before.Height / after.Height));
        }
        return found;
    }

    private static string Values(CompareChange change) => change.Kind switch
    {
        ChangeKind.Added => Short(change.NewText),
        ChangeKind.Removed => Short(change.OldText),
        _ => change.OldText.Length > 0 && change.NewText.Length > 0 ? Short(change.OldText + " → " + change.NewText) : Short(change.NewText + change.OldText),
    };

    private static string TextTitle(CompareChange change) =>
        change is { Kind: ChangeKind.Changed, OldText.Length: > 0, NewText.Length: > 0 } ? Short(change.OldText + " → " + change.NewText)
            : Short(change.Kind == ChangeKind.Removed ? change.OldText : change.NewText);

    private static string Short(string text)
    {
        string flat = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return flat.Length <= MaxTitle ? flat : flat[..(MaxTitle - 1)] + "…";
    }

    private static string Where(int oldPage, int newPage)
    {
        if (oldPage < 0 && newPage < 0) return "";
        if (newPage < 0) return Loc.T("Page {0} of the old file", oldPage + 1);
        if (oldPage < 0 || oldPage == newPage) return Loc.T("Page {0}", newPage + 1);
        return Loc.T("Page {0}, was {1}", newPage + 1, oldPage + 1);
    }

    private static IReadOnlyList<Rect> Boxes(PdfDocument document, int page, IReadOnlyList<TextQuad> quads)
    {
        if (page < 0 || page >= document.Pages.Count || quads.Count == 0) return [];
        var geometry = new PageGeometry(document.Pages[page]);
        return [.. quads.Take(MaxBoxes).Select(q =>
        {
            var box = geometry.ToDisplay(q.Bounds);
            return new Rect(box.X, box.Y, box.Width, box.Height);
        })];
    }

    private static Rect? Union(IReadOnlyList<Rect> boxes) => boxes.Count == 0 ? null : boxes.Aggregate(Rect.Union);
}
