using System.Text;
using System.Windows.Automation;
using System.Windows.Automation.Provider;
using System.Windows.Automation.Text;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Viewer;

/// <summary>
/// A stretch of the UI Automation text of the document. It keeps its two places and the tab and revision it was
/// made under, nothing of the text: once the viewer shows another tab or the file changed, every call throws
/// <see cref="ElementNotAvailableException"/> and the client asks for a new range.
/// </summary>
internal sealed class PageTextRange : ITextRangeProvider
{
    private readonly WeakReference<ITextHost> _host;
    private readonly WeakReference<DocumentTab> _tab;
    private readonly WeakReference<PageTextProvider>? _provider;
    private readonly int _revision;
    private DocPos _start;
    private DocPos _end;

    private PageTextRange(ITextHost host, PageTextProvider? provider, DocumentTab tab, int revision, DocPos start, DocPos end)
    {
        _provider = provider is null ? null : new WeakReference<PageTextProvider>(provider);
        _host = new WeakReference<ITextHost>(host);
        _tab = new WeakReference<DocumentTab>(tab);
        _revision = revision;
        (_start, _end) = (start, end);
    }

    /// <summary>A range of the document the host shows now, or null when it shows none.</summary>
    public static PageTextRange? Create(ITextHost host, DocPos start, DocPos end, PageTextProvider? provider = null)
    {
        if (host.Tab is not { } tab) return null;
        var units = Units(host);
        start = units.Normalize(start);
        end = units.Normalize(end);
        return new PageTextRange(host, provider, tab, host.Revision, start, end < start ? start : end);
    }

    public (DocPos Start, DocPos End) Places
    {
        get
        {
            Checked();
            return (_start, _end);
        }
    }

    public PageTextRange Clone()
    {
        var (host, _) = Checked();
        _tab.TryGetTarget(out var tab);
        return new PageTextRange(host, Provider, tab!, _revision, _start, _end);
    }

    ITextRangeProvider ITextRangeProvider.Clone() => Clone();

    public bool Compare(ITextRangeProvider range)
    {
        var (host, _) = Checked();
        if (range is not PageTextRange other) return false;
        var (otherHost, _) = other.Checked();
        return ReferenceEquals(host, otherHost) && _start == other._start && _end == other._end;
    }

    public int CompareEndpoints(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint)
    {
        Checked();
        var target = Same(targetRange);
        return Place(endpoint).CompareTo(target.Place(targetEndpoint));
    }

    public void ExpandToEnclosingUnit(TextUnit unit)
    {
        var (_, units) = Checked();
        var span = units.Enclosing(_start, unit);
        if (span.Unloaded >= 0 && span.Start == span.End) return;
        (_start, _end) = (span.Start, span.End);
    }

    public int Move(TextUnit unit, int count)
    {
        var (_, units) = Checked();
        if (_start == _end)
        {
            var walk = units.Move(_start, unit, count);
            _start = _end = walk.Pos;
            return walk.Moved;
        }
        var span = units.Enclosing(_start, unit);
        if (span.Unloaded >= 0 && span.Start == span.End) return 0;
        var moved = units.Move(span.Start, unit, count);
        // A last unit has to be whole: one that runs into a page that is not loaded, or the end of the document, is not moved to.
        if (moved.Moved != 0 && (moved.Pos >= units.End || units.Enclosing(moved.Pos, unit).Unloaded >= 0))
            moved = units.Move(span.Start, unit, moved.Moved - Math.Sign(moved.Moved));
        (_start, _end) = (moved.Pos, units.Enclosing(moved.Pos, unit).End);
        return moved.Moved;
    }

    public int MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit, int count)
    {
        var (_, units) = Checked();
        var walk = units.Move(Place(endpoint), unit, count);
        Set(endpoint, walk.Pos);
        return walk.Moved;
    }

    public void MoveEndpointByRange(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint)
    {
        Checked();
        Set(endpoint, Same(targetRange).Place(targetEndpoint));
    }

    /// <summary>
    /// The text of the range, up to <paramref name="maxLength"/> characters (-1 for no limit). It stops at the first page
    /// that is not loaded, which is then requested; the text before it is the same every time for the same pages.
    /// </summary>
    public string GetText(int maxLength)
    {
        if (maxLength < -1) throw new ArgumentOutOfRangeException(nameof(maxLength));
        var (host, _) = Checked();
        var text = new StringBuilder();
        int limit = maxLength < 0 ? int.MaxValue : maxLength;
        for (int page = _start.Page; page <= _end.Page && page < host.PageCount && text.Length < limit; page++)
        {
            if (host.Peek(page) is not { } loaded) break;
            string whole = PageUiaText.Of(loaded).Text;
            int from = page == _start.Page ? Math.Min(_start.Offset, whole.Length) : 0;
            int to = page == _end.Page ? Math.Min(_end.Offset, whole.Length) : whole.Length;
            if (to > from) text.Append(whole, from, Math.Min(to - from, limit - text.Length));
        }
        return text.ToString();
    }

    // TODO: search, attributes and the geometry answers come with the steps after this one; until then they report nothing.
    public ITextRangeProvider? FindText(string text, bool backward, bool ignoreCase)
    {
        Checked();
        return null;
    }

    public ITextRangeProvider? FindAttribute(int attribute, object value, bool backward)
    {
        Checked();
        return null;
    }

    public object GetAttributeValue(int attribute)
    {
        Checked();
        return AutomationElement.NotSupported;
    }

    public double[] GetBoundingRectangles()
    {
        Checked();
        return [];
    }

    public void ScrollIntoView(bool alignToTop) => Checked();

    // A place only: the reader's position is kept for GetSelection and the viewer's own selection is left alone.
    public void Select()
    {
        var (host, units) = Checked();
        if (_start == _end) host.AutomationCaret = units.ToCaret(_start);
    }

    public void AddToSelection() => throw new InvalidOperationException("The text takes one selection.");

    public void RemoveFromSelection() => throw new InvalidOperationException("The text takes one selection.");

    public IRawElementProviderSimple GetEnclosingElement()
    {
        Checked();
        return Provider?.Element ?? throw new ElementNotAvailableException();
    }

    public IRawElementProviderSimple[] GetChildren()
    {
        Checked();
        return Provider?.ChildrenIn(_start, _end) ?? [];
    }

    // Another range of the same document, which has to be available too.
    private PageTextRange Same(ITextRangeProvider range)
    {
        var (host, _) = Checked();
        if (range is not PageTextRange other) throw new ArgumentException("Not a range of this document.", nameof(range));
        var (otherHost, _) = other.Checked();
        if (!ReferenceEquals(host, otherHost)) throw new ArgumentException("The range belongs to another document.", nameof(range));
        return other;
    }

    private PageTextProvider? Provider => _provider is not null && _provider.TryGetTarget(out var provider) ? provider : null;

    private DocPos Place(TextPatternRangeEndpoint endpoint) => endpoint == TextPatternRangeEndpoint.Start ? _start : _end;

    // The other end follows when this one passes it, so a range never ends before it starts.
    private void Set(TextPatternRangeEndpoint endpoint, DocPos place)
    {
        if (endpoint == TextPatternRangeEndpoint.Start)
        {
            _start = place;
            if (_end < place) _end = place;
        }
        else
        {
            _end = place;
            if (place < _start) _start = place;
        }
    }

    private (ITextHost Host, DocumentUnits Units) Checked()
    {
        if (_host.TryGetTarget(out var host) && _tab.TryGetTarget(out var tab) && ReferenceEquals(host.Tab, tab) && host.Revision == _revision)
            return (host, Units(host));
        throw new ElementNotAvailableException();
    }

    public static DocumentUnits Units(ITextHost host) =>
        new(host.PageCount, page => host.Peek(page) is { } text ? PageUiaText.Of(text) : null);
}
