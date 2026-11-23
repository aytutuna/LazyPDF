using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>A text host over canned pages; a null page is one that is not loaded. Every page asked for and missing is noted.</summary>
internal sealed class FakeTextHost(DocumentTab? tab, int pageCount, Func<int, TextPage?> pages) : ITextHost
{
    public Func<int, TextPage?> Pages { get; set; } = pages;

    public DocumentTab? Tab { get; set; } = tab;

    public int Revision => Tab?.Revision ?? 0;

    public int PageCount { get; set; } = pageCount;

    public bool LayoutReady { get; set; } = true;

    public (Caret Anchor, Caret Focus)? Selection { get; set; }

    public Caret? BrowsingCaret { get; set; }

    public Caret? AutomationCaret { get; set; }

    public HashSet<int> Requested { get; } = [];

    public TextPage? Peek(int page)
    {
        if (Pages(page) is { } text) return text;
        Requested.Add(page);
        return null;
    }

    public static DocumentTab NewTab() => new(PdfEditSession.Open(Pdfs.Text()), new FakeRenderer(), null, "a.pdf");
}
