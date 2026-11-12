using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// The text of one revision of a file: its pages as <see cref="TextPage"/>s, made on the thread pool from a
/// document of the viewer's own, since the tab's document belongs to the UI thread and to whatever tool is
/// editing it. One source is made per revision and dropped when the file changes.
/// </summary>
public sealed class TextSource
{
    // Pages of text are far bigger in memory than on the page: a character is an object with its box. This keeps the
    // pages read for the window and a search, a few hundred, not the file.
    private const int CachedCharacters = 300_000;

    // Pages handed out and still at hand for Peek; the rest are read again from the cache, or the file.
    private const int Recent = 48;

    private readonly TextCache _cache;
    private readonly Dictionary<int, Task<TextPage?>> _pages = [];
    private readonly Queue<int> _order = new();
    private int _keep = Recent;

    private TextSource(PdfDocument document)
    {
        _cache = new TextCache(document, CachedCharacters);
        PageCount = _cache.PageCount;
    }

    public int PageCount { get; }

    /// <summary>Reads the bytes again for text; null when the engine cannot open them with what the tab was opened with.</summary>
    public static Task<TextSource?> OpenAsync(byte[] bytes, string? password, X509Certificate2? certificate = null) => Task.Run(() =>
    {
        try
        {
            return new TextSource(certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate));
        }
        catch (PdfReadException)
        {
            return null;
        }
    });

    /// <summary>Keeps at least the text of <paramref name="visible"/> pages at hand, so a window full of selected pages does not push its own pages out. UI thread only.</summary>
    public void Retain(int visible) => _keep = Math.Max(Recent, visible + 8);

    /// <summary>The text of a page if it has been made already. UI thread only.</summary>
    public TextPage? Peek(int page) =>
        _pages.TryGetValue(page, out var task) && task.IsCompletedSuccessfully ? task.Result : null;

    /// <summary>The text of a page, made on first use. UI thread only.</summary>
    public Task<TextPage?> GetAsync(int page)
    {
        if ((uint)page >= (uint)PageCount) return Task.FromResult<TextPage?>(null);
        if (_pages.TryGetValue(page, out var task)) return task;
        _pages[page] = task = Task.Run<TextPage?>(() => _cache.Get(page));
        _order.Enqueue(page);
        while (_order.Count > _keep) _pages.Remove(_order.Dequeue());
        return task;
    }

    /// <summary>Every match, page by page, as they are found; run it off the UI thread. Throws <see cref="OperationCanceledException"/>.</summary>
    public IEnumerable<SearchMatch> Find(string query, TextSearchOptions options, CancellationToken cancel, SearchTimeouts? timeouts = null) =>
        TextSearch.Find(_cache, query, options, 0, int.MaxValue, cancel, timeouts);

    /// <summary>The text of a page for the search thread, which does not go through <see cref="GetAsync"/>.</summary>
    public TextPage Page(int page) => _cache.Get(page);
}
