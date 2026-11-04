using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// The text pages of one document, built when first asked for and kept while their characters
/// stay under a cap, the least recently used going first. Safe for several threads asking, but the
/// document is read under a lock: a <see cref="PdfDocument"/> is not safe to share.
/// </summary>
public sealed class TextCache(PdfDocument document, int maxChars = 2_000_000)
{
    private readonly object _lock = new();
    private readonly Dictionary<int, LinkedListNode<TextPage>> _pages = [];
    private readonly LinkedList<TextPage> _recent = new();
    private ContentInterpreter? _interpreter;
    private long _chars;

    public int PageCount => document.Pages.Count;

    public TextPage Get(int pageIndex)
    {
        lock (_lock)
        {
            if (_pages.TryGetValue(pageIndex, out var node))
            {
                _recent.Remove(node);
                _recent.AddFirst(node);
                return node.Value;
            }
            _interpreter ??= new ContentInterpreter(document);
            var page = TextPage.Create(_interpreter, document.Pages[pageIndex]);
            _pages[pageIndex] = _recent.AddFirst(page);
            _chars += page.Chars.Count;
            while (_chars > maxChars && _recent.Count > 1)
            {
                var oldest = _recent.Last!.Value;
                _recent.RemoveLast();
                _pages.Remove(oldest.PageIndex);
                _chars -= oldest.Chars.Count;
            }
            return page;
        }
    }

    /// <summary>Forgets every page, after the document was edited.</summary>
    public void Clear()
    {
        lock (_lock)
        {
            _pages.Clear();
            _recent.Clear();
            _chars = 0;
        }
    }
}
