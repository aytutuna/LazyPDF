using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>A place between two characters: <see cref="Index"/> characters of the page's text come before it.</summary>
public readonly record struct Caret(int Page, int Index) : IComparable<Caret>
{
    public int CompareTo(Caret other) => Page != other.Page ? Page.CompareTo(other.Page) : Index.CompareTo(other.Index);

    public static bool operator <(Caret a, Caret b) => a.CompareTo(b) < 0;

    public static bool operator >(Caret a, Caret b) => a.CompareTo(b) > 0;
}

/// <summary>
/// The selected text: from an anchor to a focus, across any number of pages. It holds carets only; the
/// text of a page is looked up when it is needed (<see cref="Ranges"/>), so selecting a whole document is free.
/// </summary>
public sealed class ViewerSelection
{
    public Caret Anchor { get; private set; }

    public Caret Focus { get; private set; }

    public bool IsEmpty => Anchor == Focus;

    public Caret Start => Anchor < Focus ? Anchor : Focus;

    public Caret End => Anchor < Focus ? Focus : Anchor;

    public event EventHandler? Changed;

    public void Set(Caret anchor, Caret focus)
    {
        if (Anchor == anchor && Focus == focus) return;
        Anchor = anchor;
        Focus = focus;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Moves the focus and keeps the anchor.</summary>
    public void Extend(Caret focus) => Set(Anchor, focus);

    public void Clear() => Set(default, default);

    /// <summary>Selects from the start of the first page to the end of the last (an index past the text means its end).</summary>
    public void SelectAll(int pages) => Set(new Caret(0, 0), new Caret(Math.Max(pages - 1, 0), int.MaxValue));

    public bool Covers(int page) => !IsEmpty && page >= Start.Page && page <= End.Page;

    /// <summary>The selected stretch of one page that has <paramref name="characters"/> characters, or null.</summary>
    public TextRange? On(int page, int characters)
    {
        if (!Covers(page)) return null;
        var (start, end) = (Start, End);
        int from = page == start.Page ? Math.Min(start.Index, characters) : 0;
        int to = page == end.Page ? Math.Min(end.Index, characters) : characters;
        return to > from ? new TextRange(from, to) : null;
    }

    /// <summary>The stretch of each page's characters that is selected, given how many characters each page has.</summary>
    public IEnumerable<(int Page, TextRange Range)> Ranges(Func<int, int> characters)
    {
        if (IsEmpty) yield break;
        for (int page = Start.Page; page <= End.Page; page++)
        {
            if (On(page, characters(page)) is { } range) yield return (page, range);
        }
    }
}
