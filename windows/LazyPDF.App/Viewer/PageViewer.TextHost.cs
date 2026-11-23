using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// The text a screen reader reads: a page that is loaded is answered at once, one that is not is requested and
// answered with null, so a provider call never waits for the pool or parses a page on the UI thread.
public partial class PageViewer : ITextHost
{
    // How far past the last page a reader used, and before the first, text is loaded ahead of it.
    private const int ReadAheadAfter = 8;
    private const int ReadAheadBefore = 2;

    private readonly HashSet<int> _pending = [];
    private readonly HashSet<int> _wanted = [];
    private (int First, int Last)? _readRange;
    private bool _unreadable;
    private DocPos? _automationCaret;

    DocumentTab? ITextHost.Tab => _tab;

    int ITextHost.Revision => _tab?.Revision ?? 0;

    int ITextHost.PageCount => _tab?.PageCount ?? 0;

    bool ITextHost.LayoutReady => !_stale && _tab is { } tab && Surface.PageCount == tab.PageCount;

    (Caret Anchor, Caret Focus)? ITextHost.Selection => _selection.IsEmpty ? null : (_selection.Anchor, _selection.Focus);

    bool ITextHost.SetSelection(Caret anchor, Caret focus)
    {
        if (_tab is null) return false;
        // A drag still under way would take the selection back.
        CancelPendingSelection();
        // The same selection raises no change, yet the reader's caret is replaced by it all the same.
        bool same = _selection.Anchor == anchor && _selection.Focus == focus;
        _automationCaret = null;
        _selection.Set(anchor, focus);
        if (same) Surface.TellSelection();
        return true;
    }

    Caret? ITextHost.BrowsingCaret => _caretMode ? _selection.Focus : null;

    DocPos? ITextHost.AutomationCaret
    {
        get => _automationCaret;
        set
        {
            _automationCaret = value;
            if (value is not null) Surface.TellSelection();
        }
    }

    TextPage? ITextHost.Peek(int page)
    {
        if (_tab is not { } tab || (uint)page >= (uint)tab.PageCount) return null;
        NoteReading(page);
        if (_unreadable) return TextPage.Empty(page);
        if (_source?.Peek(page) is { } text) return text;
        _wanted.Add(page);
        Request(page);
        return null;
    }

    private void Request(int page)
    {
        if (_pending.Add(page)) _ = Fetch(page);
    }

    private async Task Fetch(int page)
    {
        try
        {
            var open = TextAsync();
            if (await open is null && ReferenceEquals(open, _text))
            {
                _unreadable = true;
                PageArrived(page);
            }
            else
            {
                await GetTextAsync(page);
            }
        }
        finally
        {
            _pending.Remove(page);
        }
    }

    // The pages a reader touches in one burst of calls are one range; loading ahead of it waits for the burst to end.
    private void NoteReading(int page)
    {
        if (_readRange is (var first, var last))
        {
            _readRange = (Math.Min(first, page), Math.Max(last, page));
            return;
        }
        _readRange = (page, page);
        Dispatcher.InvokeAsync(ReadAhead, DispatcherPriority.Background);
    }

    private void ReadAhead()
    {
        if (_readRange is not (var first, var last) || _tab is not { } tab) return;
        _readRange = null;
        // Only the ends: pages between two far apart ones touched in the same burst are no business of the reader.
        for (int page = Math.Max(first - ReadAheadBefore, 0); page < first; page++) RequestIfMissing(page);
        for (int page = last + 1; page <= Math.Min(last + ReadAheadAfter, tab.PageCount - 1); page++) RequestIfMissing(page);
    }

    private void RequestIfMissing(int page)
    {
        if (!_unreadable && _source?.Peek(page) is null) Request(page);
    }

    // A page arrived from the pool, whoever asked for it.
    private void PageArrived(int page)
    {
        Surface.TextLoaded(page, _wanted.Remove(page));
    }

    // What a reader read is gone; ranges it holds stay valid while the tab and its revision do, and read the new text.
    private void TextReset()
    {
        _pending.Clear();
        _wanted.Clear();
        _readRange = null;
        _unreadable = false;
        _automationCaret = null;
        Surface.TextReset();
    }
}
