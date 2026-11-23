using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>What the page surface's screen reader provider needs from the viewer that owns it. Every member runs on the UI thread and returns at once.</summary>
public interface ITextHost
{
    /// <summary>The tab the viewer shows, or null.</summary>
    DocumentTab? Tab { get; }

    /// <summary>The tab's revision; a place or range made under another one is stale.</summary>
    int Revision { get; }

    /// <summary>The page count of the text document, the tab's at its revision. The surface's own count can lag behind it.</summary>
    int PageCount { get; }

    /// <summary>The surface lays out the pages of the text document, so positions on the screen mean something.</summary>
    bool LayoutReady { get; }

    /// <summary>
    /// The text of a page if it is loaded. Otherwise null, and the page is requested; a loaded page with no text is a
    /// real, empty page. Never reads or waits for a page itself.
    /// </summary>
    TextPage? Peek(int page);
}
