using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Where new pages go, relative to the selection.</summary>
public enum InsertPlace { AfterSelection, BeforeSelection, AtStart, AtEnd }

/// <summary>A paper size for Resize, in points.</summary>
public sealed record PaperSize(string Name, double Width, double Height)
{
    public static readonly IReadOnlyList<PaperSize> All =
    [
        new("A4", 595.276, 841.89),
        new("A3", 841.89, 1190.551),
        new("A5", 419.528, 595.276),
        new(Loc.T("Letter"), 612, 792),
        new(Loc.T("Legal"), 612, 1008),
    ];
}

/// <summary>What the Pages panel does to the document, apart from the controls. Each call changes the document in memory; the panel commits.</summary>
internal static class PageEdits
{
    public const double PointsPerMillimetre = 72 / 25.4;

    /// <summary>A second copy of the file as it stands, for work on another thread.</summary>
    public static PdfDocument Reopen(DocumentTab tab)
    {
        byte[] bytes = tab.Session.Current.ToArray();
        return tab.Certificate is { } certificate ? PdfDocument.Open(bytes, certificate) : PdfDocument.Open(bytes, tab.Password);
    }

    public static int InsertAt(InsertPlace place, IReadOnlyCollection<int> selection, int pageCount) => place switch
    {
        InsertPlace.AtStart => 0,
        InsertPlace.AtEnd => pageCount,
        _ when selection.Count == 0 => pageCount,
        InsertPlace.BeforeSelection => selection.Min(),
        _ => selection.Max() + 1,
    };

    /// <summary>The size a blank page takes: that of the page next to where it goes.</summary>
    public static (double Width, double Height) NeighbourSize(PdfDocument document, int at)
    {
        var page = document.Pages[Math.Clamp(at - 1, 0, document.Pages.Count - 1)];
        var geometry = new PageGeometry(page);
        return (geometry.Width, geometry.Height);
    }

    /// <summary>Replaces <paramref name="pages"/> with <paramref name="sourcePages"/> of another file, at the place of the last of them.</summary>
    public static void Replace(PdfDocument target, IReadOnlyCollection<int> pages, PdfDocument source, IReadOnlyList<int> sourcePages)
    {
        PageOperations.ImportPages(target, source, sourcePages, pages.Max() + 1);
        PageOperations.Delete(target, pages);
    }

    /// <summary>Where the moved pages stand after <see cref="PageOperations.Move"/> put them before page <paramref name="before"/>.</summary>
    public static IEnumerable<int> MovedTo(IReadOnlyCollection<int> pages, int before) =>
        Enumerable.Range(before - pages.Count(p => p < before), pages.Count);

    /// <summary>Moves each chosen page one place past the unchosen page next to it; a run of pages at the edge stays.</summary>
    public static void Nudge(PdfDocument document, IReadOnlyCollection<int> pages, int step)
    {
        int total = document.Pages.Count;
        var runs = new List<List<int>>();
        foreach (int page in pages.Order())
        {
            if (runs.Count > 0 && runs[^1][^1] == page - 1) runs[^1].Add(page);
            else runs.Add([page]);
        }
        if (step > 0) runs.Reverse();
        foreach (var run in runs)
        {
            if (step < 0 ? run[0] == 0 : run[^1] == total - 1) continue;
            PageOperations.Move(document, run, step < 0 ? run[0] - 1 : run[^1] + 2);
        }
    }

    /// <summary>Where the chosen pages stand after <see cref="Nudge"/>.</summary>
    public static IEnumerable<int> Nudged(IReadOnlyCollection<int> pages, int step, int total)
    {
        var chosen = pages.ToHashSet();
        foreach (int page in pages)
        {
            int end = page;
            while (chosen.Contains(end + step)) end += step;
            yield return end + step < 0 || end + step >= total ? page : page + step;
        }
    }

    /// <summary>Whether any chosen page has an unchosen page to step past.</summary>
    public static bool CanNudge(IReadOnlyCollection<int> pages, int step, int total) =>
        pages.Any(p => p + step >= 0 && p + step < total && !pages.Contains(p + step));

    /// <summary>Where the pages and their copies stand after <see cref="PageOperations.Duplicate"/>.</summary>
    public static IEnumerable<int> Duplicated(IReadOnlyCollection<int> pages)
    {
        var ordered = pages.Order().ToList();
        for (int i = 0; i < ordered.Count; i++)
        {
            yield return ordered[i] + i;
            yield return ordered[i] + i + 1;
        }
    }

    /// <summary>Resizes to the paper size, each page keeping its orientation.</summary>
    public static void ResizeTo(PdfDocument document, IReadOnlyCollection<int> pages, double width, double height, ResizeMode mode)
    {
        double shortSide = Math.Min(width, height), longSide = Math.Max(width, height);
        var portrait = new List<int>();
        var landscape = new List<int>();
        foreach (int page in pages)
        {
            var shown = new PageGeometry(document.Pages[page]);
            (shown.Width > shown.Height ? landscape : portrait).Add(page);
        }
        if (portrait.Count > 0) PageOperations.Resize(document, portrait, shortSide, longSide, mode);
        if (landscape.Count > 0) PageOperations.Resize(document, landscape, longSide, shortSide, mode);
    }

    /// <summary>The pages the display rectangle touches; the others would refuse it as a crop box.</summary>
    public static List<int> CropTargets(PdfDocument document, IReadOnlyCollection<int> pages, DisplayRect area) =>
        [.. pages.Where(p => !new PageGeometry(document.Pages[p]).ToUser(area).Intersect(document.Pages[p].MediaBox).IsEmpty)];

    /// <summary>Sets the display rectangle (page space of the page it was drawn on) as the crop box of every page, each through its own geometry.</summary>
    public static void Crop(PdfDocument document, IReadOnlyCollection<int> pages, DisplayRect area)
    {
        foreach (int page in pages)
        {
            var box = new PageGeometry(document.Pages[page]).ToUser(area);
            PageOperations.SetBox(document, [page], PageBox.Crop, box);
        }
    }

    /// <summary>
    /// Numbers pages <paramref name="first"/> to <paramref name="last"/> as given. The pages after keep the labels they had:
    /// a range that started inside is cut, and the one in force after <paramref name="last"/> is started again there.
    /// </summary>
    public static void Relabel(PdfDocument document, int first, int last, PageLabelStyle style, string prefix, int start)
    {
        var old = PdfPageLabels.Read(document);
        var ranges = old.Where(r => r.StartPage < first).ToList();
        ranges.Add(new PageLabelRange(first, style, prefix, start));
        int next = last + 1;
        if (next < document.Pages.Count)
        {
            var inForce = old.Where(r => r.StartPage <= next).MaxBy(r => r.StartPage);
            if (inForce is null) ranges.Add(new PageLabelRange(next, PageLabelStyle.Decimal, "", next + 1));
            else if (inForce.StartPage == next) ranges.Add(inForce);
            else ranges.Add(inForce with { StartPage = next, FirstNumber = inForce.FirstNumber + next - inForce.StartPage });
            ranges.AddRange(old.Where(r => r.StartPage > next));
        }
        PdfPageLabels.Write(document, ranges);
    }

    public static void ClearLabels(PdfDocument document) => PdfPageLabels.Write(document, []);

    /// <summary>The pages of the selection as a run from the first to the last: labels are ranges, so gaps cannot be left out.</summary>
    public static (int First, int Last) Span(IReadOnlyCollection<int> selection) => (selection.Min(), selection.Max());
}
