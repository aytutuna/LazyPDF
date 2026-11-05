using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>One entry of the review list: the mark and a few words to know it by.</summary>
public sealed record MarkItem(RedactionMark Mark, string Label)
{
    public int Page => Mark.Page;

    public string PageText => Loc.T("Page {0}", Page + 1);

    public string Spoken => Loc.T("{0}, page {1}", Label, Page + 1);
}

/// <summary>What is marked on a document so far, in reading order. Nothing is written to the file until the redaction is applied.</summary>
public sealed class MarkList
{
    private const double SamePlace = 0.5;

    // Marks by page and the unit square of their first corner, so that a new one is compared only with its neighbours.
    private readonly Dictionary<(int Page, int X, int Y), List<MarkItem>> _cells = [];
    private List<MarkItem> _items = [];

    public IReadOnlyList<MarkItem> Items => _items;

    public event EventHandler? Changed;

    /// <summary>Adds what is not marked already and returns how many were new.</summary>
    public int Add(IEnumerable<MarkItem> items)
    {
        int added = 0;
        foreach (var item in items)
        {
            if (Neighbours(item).Any(m => Same(m.Mark, item.Mark))) continue;
            var cell = Cell(item);
            if (!_cells.TryGetValue(cell, out var inCell)) _cells[cell] = inCell = [];
            inCell.Add(item);
            _items.Add(item);
            added++;
        }
        if (added == 0) return 0;
        _items = [.. _items.OrderBy(m => m.Page).ThenByDescending(m => Top(m.Mark)).ThenBy(m => Left(m.Mark))];
        Changed?.Invoke(this, EventArgs.Empty);
        return added;
    }

    public void Remove(MarkItem item)
    {
        if (!_items.Remove(item)) return;
        _cells[Cell(item)].Remove(item);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        if (_items.Count == 0) return;
        _items.Clear();
        _cells.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static (int Page, int X, int Y) Cell(MarkItem item)
    {
        var box = item.Mark.Quads[0].Bounds;
        return (item.Page, (int)Math.Floor(box.Left), (int)Math.Floor(box.Bottom));
    }

    private IEnumerable<MarkItem> Neighbours(MarkItem item)
    {
        var (page, x, y) = Cell(item);
        for (int dx = -1; dx <= 1; dx++)
        {
            for (int dy = -1; dy <= 1; dy++)
            {
                if (!_cells.TryGetValue((page, x + dx, y + dy), out var inCell)) continue;
                foreach (var m in inCell) yield return m;
            }
        }
    }

    private static double Top(RedactionMark mark) => mark.Quads.Max(q => q.Bounds.Top);

    private static double Left(RedactionMark mark) => mark.Quads.Min(q => q.Bounds.Left);

    private static bool Same(RedactionMark a, RedactionMark b)
    {
        if (a.Page != b.Page || a.Quads.Count != b.Quads.Count) return false;
        return a.Quads.Zip(b.Quads).All(p => Near(p.First.Bounds, p.Second.Bounds));
    }

    private static bool Near(PdfRect a, PdfRect b) =>
        Math.Abs(a.Left - b.Left) < SamePlace && Math.Abs(a.Bottom - b.Bottom) < SamePlace
        && Math.Abs(a.Right - b.Right) < SamePlace && Math.Abs(a.Top - b.Top) < SamePlace;
}
