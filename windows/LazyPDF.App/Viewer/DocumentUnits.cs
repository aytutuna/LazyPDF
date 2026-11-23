using System.Windows.Automation.Text;

namespace LazyPDF.App.Viewer;

/// <summary>A place in the UI Automation text of a document: an offset in the string of a page. The end of the document is (page count, 0).</summary>
public readonly record struct DocPos(int Page, int Offset) : IComparable<DocPos>
{
    public int CompareTo(DocPos other) => Page != other.Page ? Page.CompareTo(other.Page) : Offset.CompareTo(other.Offset);

    public static bool operator <(DocPos a, DocPos b) => a.CompareTo(b) < 0;

    public static bool operator >(DocPos a, DocPos b) => a.CompareTo(b) > 0;

    public static bool operator <=(DocPos a, DocPos b) => a.CompareTo(b) <= 0;

    public static bool operator >=(DocPos a, DocPos b) => a.CompareTo(b) >= 0;
}

/// <summary>Where a move ended and how many units it covered (negative backwards); <see cref="Unloaded"/> is the page whose text it ran into, or -1.</summary>
public readonly record struct Walk(DocPos Pos, int Moved, int Unloaded);

/// <summary>The unit around a place; <see cref="Unloaded"/> as in <see cref="Walk"/>.</summary>
public readonly record struct UnitSpan(DocPos Start, DocPos End, int Unloaded);

/// <summary>
/// Moving through the UI Automation text of a document by character, format run, word, line, paragraph, page
/// and document. A page that is not loaded (null from <c>pages</c>) has no text to walk over: a walk stops at
/// its start, or just inside the page it came from, and says which page it needs. No unit crosses a page.
/// </summary>
public sealed class DocumentUnits
{
    private readonly int _count;
    private readonly Func<int, PageUiaText?> _pages;

    public DocumentUnits(int pageCount, Func<int, PageUiaText?> pages)
    {
        _count = pageCount;
        _pages = pages;
    }

    public int PageCount => _count;

    public DocPos Start => default;

    public DocPos End => new(_count, 0);

    /// <summary>
    /// The one form of a place. An offset past the end of a loaded page is the start of the next; one on a page that
    /// is not loaded can only be kept, so it stays as it is.
    /// </summary>
    public DocPos Normalize(DocPos at)
    {
        if (at.Page < 0) return Start;
        if (at.Page >= _count) return End;
        int offset = Math.Max(at.Offset, 0);
        if (offset > 0 && _pages(at.Page) is { } text && offset >= text.Length) return After(at.Page);
        return new DocPos(at.Page, offset);
    }

    /// <summary>
    /// The place of a caret of the viewer's selection; an index past the characters of the page, int.MaxValue included, is its end.
    /// On a page that is not loaded an index above 0 cannot be placed: the page starts there and is named as <c>Unloaded</c>.
    /// </summary>
    public (DocPos Pos, int Unloaded) FromCaret(Caret caret)
    {
        if (caret.Page < 0) return (Start, -1);
        if (caret.Page >= _count) return (End, -1);
        if (_pages(caret.Page) is { } text) return (Normalize(new DocPos(caret.Page, text.OffsetOf(Math.Max(caret.Index, 0)))), -1);
        if (caret.Index == int.MaxValue) return (After(caret.Page), -1);
        return (new DocPos(caret.Page, 0), caret.Index > 0 ? caret.Page : -1);
    }

    /// <summary>The caret of the viewer's selection that stands for a place; the end of the document is the end of its last page.</summary>
    public Caret ToCaret(DocPos at)
    {
        var pos = Normalize(at);
        if (pos.Page >= _count) return new Caret(Math.Max(_count - 1, 0), int.MaxValue);
        return new Caret(pos.Page, _pages(pos.Page) is { } text ? text.CharStart(pos.Offset) : 0);
    }

    /// <summary>
    /// The carets of a selection that covers the stretch, snapped outwards to whole characters: the start to the
    /// character holding its unit, the end to the one after the character holding its last unit. Null when the
    /// stretch covers no character or a page it needs is not loaded.
    /// </summary>
    public (Caret Anchor, Caret Focus)? Selection(DocPos start, DocPos end)
    {
        start = Normalize(start);
        end = Normalize(end);
        if (start >= end || start.Page >= _count) return null;
        Caret from, to;
        if (_pages(start.Page) is { } first) from = new Caret(start.Page, first.CharStart(start.Offset));
        else if (start.Offset == 0) from = new Caret(start.Page, 0);
        else return null;
        if (end.Page >= _count) to = new Caret(_count - 1, int.MaxValue);
        else if (_pages(end.Page) is { } last) to = new Caret(end.Page, last.CharEnd(end.Offset));
        else if (end.Offset == 0) to = new Caret(end.Page, 0);
        else return null;
        return to > from ? (from, to) : null;
    }

    public Walk Move(DocPos from, TextUnit unit, int count)
    {
        var pos = Normalize(from);
        int moved = 0, unloaded = -1;
        bool forward = count > 0;
        for (long left = Math.Abs((long)count); left > 0; left--)
        {
            var (next, blocked) = Step(pos, unit, forward);
            if (blocked >= 0) unloaded = blocked;
            if (next == pos) break;
            pos = next;
            moved += forward ? 1 : -1;
        }
        return new Walk(pos, moved, unloaded);
    }

    public UnitSpan Enclosing(DocPos at, TextUnit unit)
    {
        var pos = Normalize(at);
        if (pos.Page >= _count)
        {
            if (unit != TextUnit.Document) return new UnitSpan(pos, pos, -1);
            var (first, missing) = ToStart(pos);
            return new UnitSpan(first, pos, missing);
        }
        if (_pages(pos.Page) is not { } text) return new UnitSpan(pos, pos, pos.Page);
        switch (unit)
        {
            case TextUnit.Document:
                var (end, after) = Step(pos, unit, true);
                var (start, before) = Step(pos, unit, false);
                return new UnitSpan(start, end, Math.Max(after, before));
            case TextUnit.Character:
                return new UnitSpan(pos, Step(pos, unit, true).Pos, -1);
        }
        var starts = text.Starts(unit)!;
        int index = Array.BinarySearch(starts, pos.Offset);
        if (index < 0) index = ~index - 1;
        int next = index + 1 < starts.Length ? starts[index + 1] : -1;
        return new UnitSpan(new DocPos(pos.Page, starts[index]), next < 0 ? After(pos.Page) : new DocPos(pos.Page, next), -1);
    }

    private DocPos After(int page) => page + 1 >= _count ? End : new DocPos(page + 1, 0);

    private (DocPos Pos, int Unloaded) Step(DocPos pos, TextUnit unit, bool forward)
    {
        if (unit == TextUnit.Document) return forward ? ToEnd(pos) : ToStart(pos);
        return forward ? StepForward(pos, unit) : StepBack(pos, unit);
    }

    private (DocPos, int) StepForward(DocPos pos, TextUnit unit)
    {
        if (pos.Page >= _count) return (pos, -1);
        if (_pages(pos.Page) is not { } text) return (pos, pos.Page);
        int next;
        if (unit == TextUnit.Character)
        {
            next = pos.Offset + (IsPair(text.Text, pos.Offset) ? 2 : 1);
        }
        else
        {
            var starts = text.Starts(unit)!;
            int index = Array.BinarySearch(starts, pos.Offset);
            index = index < 0 ? ~index : index + 1;
            next = index < starts.Length ? starts[index] : text.Length;
        }
        return (next >= text.Length ? After(pos.Page) : new DocPos(pos.Page, next), -1);
    }

    private (DocPos, int) StepBack(DocPos pos, TextUnit unit)
    {
        bool fromEnd;
        int page;
        if (pos.Page >= _count)
        {
            if (_count == 0) return (pos, -1);
            (page, fromEnd) = (_count - 1, true);
        }
        else if (pos.Offset == 0)
        {
            if (pos.Page == 0) return (pos, -1);
            (page, fromEnd) = (pos.Page - 1, true);
        }
        else
        {
            (page, fromEnd) = (pos.Page, false);
        }
        if (_pages(page) is not { } text) return (pos, page);
        int offset = fromEnd ? text.Length : pos.Offset;
        int previous;
        if (unit == TextUnit.Character)
        {
            previous = offset - 1;
            if (previous > 0 && char.IsLowSurrogate(text.Text[previous]) && char.IsHighSurrogate(text.Text[previous - 1])) previous--;
        }
        else
        {
            var starts = text.Starts(unit)!;
            int index = Array.BinarySearch(starts, offset);
            previous = starts[(index < 0 ? ~index : index) - 1];
        }
        return (new DocPos(page, previous), -1);
    }

    // The document is one unit, but only as far as the pages in a row that are loaded.
    private (DocPos, int) ToEnd(DocPos pos)
    {
        if (pos.Page >= _count) return (pos, -1);
        for (int page = pos.Page; page < _count; page++)
        {
            if (_pages(page) is not null) continue;
            return (page == pos.Page ? pos : new DocPos(page, 0), page);
        }
        return (End, -1);
    }

    private (DocPos, int) ToStart(DocPos pos)
    {
        int first = pos.Page >= _count || pos.Offset == 0 ? Math.Min(pos.Page, _count) - 1 : pos.Page;
        for (int page = first; page >= 0; page--)
        {
            if (_pages(page) is not null) continue;
            return (page == pos.Page ? pos : new DocPos(page + 1, 0), page);
        }
        return (Start, -1);
    }

    private static bool IsPair(string text, int offset) =>
        offset + 1 < text.Length && char.IsHighSurrogate(text[offset]) && char.IsLowSurrogate(text[offset + 1]);
}
