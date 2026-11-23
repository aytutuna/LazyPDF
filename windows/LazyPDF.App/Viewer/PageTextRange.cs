using System.Text;
using System.Windows.Automation;
using System.Windows.Automation.Provider;
using System.Windows.Automation.Text;
using LazyPDF.App.Documents;
using LazyPDF.Core;

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
        if (moved.Moved != 0 && moved.Pos < units.End && units.Enclosing(moved.Pos, unit).Unloaded >= 0)
        {
            // The walk reached a page that is not loaded: stop on its start so the next call can go on from there.
            (_start, _end) = (moved.Pos, moved.Pos);
            return moved.Moved;
        }
        // A last unit has to be whole, and one that runs to the end of the document is not moved to.
        if (moved.Moved != 0 && moved.Pos >= units.End)
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
        for (int page = _start.Page; (page < _end.Page || (page == _end.Page && _end.Offset > 0)) && page < host.PageCount && text.Length < limit; page++)
        {
            if (host.Peek(page) is not { } loaded) break;
            string whole = PageUiaText.Of(loaded).Text;
            int from = page == _start.Page ? Math.Min(_start.Offset, whole.Length) : 0;
            int to = page == _end.Page ? Math.Min(_end.Offset, whole.Length) : whole.Length;
            if (to > from) text.Append(whole, from, Math.Min(to - from, limit - text.Length));
        }
        return text.ToString();
    }

    /// <summary>
    /// The first (last when <paramref name="backward"/>) hit inside the range. It looks at the loaded pages only and
    /// stops at the first one that is not, which is requested; the answer is then null, as when nothing is found.
    /// </summary>
    public ITextRangeProvider? FindText(string text, bool backward, bool ignoreCase)
    {
        var (host, _) = Checked();
        if (text.Length == 0) return null;
        var options = new TextSearchOptions(MatchCase: !ignoreCase);
        int last = Math.Min(_end.Offset == 0 && _end.Page > _start.Page ? _end.Page - 1 : _end.Page, host.PageCount - 1);
        for (int i = 0, count = last - _start.Page + 1; i < count; i++)
        {
            int page = backward ? last - i : _start.Page + i;
            if (host.Peek(page) is not { } loaded) return null;
            IReadOnlyList<SearchMatch> hits;
            try
            {
                hits = TextSearch.Find(loaded, text, options);
            }
            catch (OperationCanceledException)
            {
                continue;
            }
            var units = PageUiaText.Of(loaded);
            (DocPos From, DocPos To)? found = null;
            foreach (var hit in hits)
            {
                if (hit.Range.End <= hit.Range.Start) continue;
                var (from, to) = (new DocPos(page, units.OffsetOf(hit.Range.Start)), new DocPos(page, units.EndOf(hit.Range.End - 1)));
                if (to <= from || from < _start || to > _end) continue;
                found = (from, to);
                if (!backward) break;
            }
            if (found is var (a, b)) return Create(host, a, b, Provider);
        }
        return null;
    }

    public ITextRangeProvider? FindAttribute(int attribute, object value, bool backward)
    {
        Checked();
        return null;
    }

    /// <summary>
    /// Font name, size and color of the characters of the range, reading direction, and read-only. Hidden is not
    /// reported: OCR text is drawn invisible and is the text to read.
    /// </summary>
    public object GetAttributeValue(int attribute)
    {
        var (host, _) = Checked();
        if (attribute == TextPatternIdentifiers.IsReadOnlyAttribute.Id) return true;
        Func<TextPage, TextChar, object>? read = null;
        if (attribute == TextPatternIdentifiers.FontNameAttribute.Id) read = (_, c) => c.Font?.Name ?? "";
        else if (attribute == TextPatternIdentifiers.FontSizeAttribute.Id) read = (_, c) => Math.Round(c.Size, 2);
        else if (attribute == TextPatternIdentifiers.ForegroundColorAttribute.Id) read = (_, c) => c.Color.R | c.Color.G << 8 | c.Color.B << 16;
        else if (attribute == TextPatternIdentifiers.TextFlowDirectionsAttribute.Id) read = (page, c) => page.Lines[c.Line] switch
        {
            { IsVertical: true } => FlowDirections.Vertical,
            { IsRtl: true } => FlowDirections.RightToLeft,
            _ => FlowDirections.Default,
        };
        if (read is null) return AutomationElement.NotSupported;
        object? value = null;
        foreach (var (page, c) in Characters(host))
        {
            var next = read(page, c);
            if (value is null) value = next;
            else if (!value.Equals(next)) return TextPattern.MixedAttributeValue;
        }
        return value ?? AutomationElement.NotSupported;
    }

    // The characters with text that the range covers on the pages that are loaded, up to the first one that is not; an empty range has the one it is in front of.
    private IEnumerable<(TextPage Page, TextChar Char)> Characters(ITextHost host)
    {
        for (int page = _start.Page; page < host.PageCount && (page < _end.Page || (page == _end.Page && _end.Offset > 0) || _start == _end); page++)
        {
            if (host.Peek(page) is not { } loaded) yield break;
            var text = PageUiaText.Of(loaded);
            int first = text.CharStart(page == _start.Page ? _start.Offset : 0);
            int to = _start == _end ? first + 1 : text.CharEnd(page == _end.Page ? _end.Offset : text.Length);
            for (int i = first; i < Math.Min(to, loaded.Chars.Count); i++)
            {
                var c = loaded.Chars[i];
                if (c.Text.Length > 0 && !c.IsSpace && c.Font is not null) yield return (loaded, c);
            }
            if (_start == _end) yield break;
        }
    }

    public double[] GetBoundingRectangles()
    {
        Checked();
        return Provider?.Rectangles(_start, _end) ?? [];
    }

    public void ScrollIntoView(bool alignToTop)
    {
        Checked();
        Provider?.Reveal(_start, _end, alignToTop);
    }

    // An empty range is only a place the reader keeps for GetSelection, so the user's own selection is left alone.
    public void Select()
    {
        var (host, units) = Checked();
        if (_start == _end)
        {
            host.AutomationCaret = _start;
            Provider?.Reveal(_start, _end, true);
        }
        else if (units.Selection(_start, _end) is { } selection)
        {
            host.SetSelection(selection.Anchor, selection.Focus);
        }
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
