using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>One entry of the review list: the mark and a few words to know it by.</summary>
public sealed record MarkItem(RedactionMark Mark, string Label, bool IsBox = false)
{
    public int Page => Mark.Page;

    public string PageText => Loc.T("Page {0}", Page + 1);

    public string Spoken => Loc.T("{0}, page {1}", Label, Page + 1);
}

/// <summary>What is marked on a document so far, in reading order. Nothing is written to the file until the redaction is applied.</summary>
public sealed class MarkList
{
    private const double SamePlace = 0.5;
    private const int MaxSteps = 20;

    // Marks by page and the unit square of their first corner, so that a new one is compared only with its neighbours.
    private readonly Dictionary<(int Page, int X, int Y), List<MarkItem>> _cells = [];
    private readonly List<IReadOnlyList<MarkItem>> _history = [];
    private List<MarkItem> _items = [];

    // Every change replaces the list, so a reference taken from Items never changes under its holder.
    public IReadOnlyList<MarkItem> Items => _items;

    public bool CanUndo => _history.Count > 0;

    public event EventHandler? Changed;

    /// <summary>Adds what is not marked already and returns how many were new.</summary>
    public int Add(IEnumerable<MarkItem> items)
    {
        var fresh = new List<MarkItem>();
        foreach (var item in items)
        {
            if (Neighbours(item).Any(m => Same(m.Mark, item.Mark))) continue;
            var cell = Cell(item);
            if (!_cells.TryGetValue(cell, out var inCell)) _cells[cell] = inCell = [];
            inCell.Add(item);
            fresh.Add(item);
        }
        if (fresh.Count == 0) return 0;
        Push();
        _items = Sorted(_items.Concat(fresh));
        Changed?.Invoke(this, EventArgs.Empty);
        return fresh.Count;
    }

    public void Remove(MarkItem item)
    {
        int index = _items.IndexOf(item);
        if (index < 0) return;
        Push();
        _items = [.. _items.Take(index).Concat(_items.Skip(index + 1))];
        _cells[Cell(item)].Remove(item);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Puts <paramref name="now"/> where <paramref name="old"/> was, for a box that was moved or resized. One step of Undo.</summary>
    public void Replace(MarkItem old, MarkItem now)
    {
        if (!_items.Contains(old)) return;
        Push();
        _items = Sorted(_items.Where(m => m != old).Append(now));
        RebuildCells();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        if (_items.Count == 0) return;
        Push();
        _items = [];
        _cells.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Undo()
    {
        if (_history.Count == 0) return;
        _items = [.. _history[^1]];
        _history.RemoveAt(_history.Count - 1);
        RebuildCells();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // Changed is raised so a shown Undo button goes away.
    public void Forget()
    {
        if (_history.Count == 0) return;
        _history.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void RebuildCells()
    {
        _cells.Clear();
        foreach (var item in _items)
        {
            var cell = Cell(item);
            if (!_cells.TryGetValue(cell, out var inCell)) _cells[cell] = inCell = [];
            inCell.Add(item);
        }
    }

    private static List<MarkItem> Sorted(IEnumerable<MarkItem> items) =>
        [.. items.OrderBy(m => m.Page).ThenByDescending(m => Top(m.Mark)).ThenBy(m => Left(m.Mark))];

    private void Push()
    {
        _history.Add(_items);
        if (_history.Count > MaxSteps) _history.RemoveAt(0);
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
