using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>A figure of the tag tree and the page it is on.</summary>
public sealed record FigureRow(StructElement Element, int Page, int Number)
{
    public string Alt => Element.Alt?.Trim() ?? "";

    public bool HasAlt => Alt.Length > 0;

    private string Replacement => Element.ActualText?.Trim() ?? "";

    /// <summary>What the check counts as a description: alternate text or replacement text.</summary>
    public bool HasDescription => HasAlt || Replacement.Length > 0;

    public string Title => Page >= 0 ? Loc.T("Figure {0}, page {1}", Number, Page + 1) : Loc.T("Figure {0}", Number);

    public string Summary => HasAlt ? Alt : Replacement.Length > 0 ? Replacement : Loc.T("No description");

    public string AutomationName => Title + ". " + Summary;
}

/// <summary>Finds the figures of a tag tree and the box each one covers on its page.</summary>
internal static class FigureFinder
{
    public static IReadOnlyList<FigureRow> List(StructureTree tree)
    {
        var rows = new List<FigureRow>();
        foreach (var element in tree.Elements)
        {
            if (tree.StandardType(element.Type) == "Figure") rows.Add(new FigureRow(element, PageOf(element), rows.Count + 1));
        }
        return rows;
    }

    /// <summary>The page of the first thing the element holds, or -1.</summary>
    public static int PageOf(StructElement element)
    {
        if (element.PageIndex >= 0) return element.PageIndex;
        var pending = new Stack<StructElement>([element]);
        int budget = 2000;
        while (pending.Count > 0 && budget-- > 0)
        {
            var next = pending.Pop();
            foreach (var kid in next.Kids)
            {
                if (kid is StructContent { PageIndex: >= 0 } content) return content.PageIndex;
                if (kid is StructObject { PageIndex: >= 0 } target) return target.PageIndex;
                if (kid is StructElement child) pending.Push(child);
            }
        }
        return -1;
    }

    /// <summary>
    /// What the figure draws, in page space as shown: the pictures painted inside its marked content, else its drawing.
    /// Null when the content cannot be found, as for a figure whose tag has no content of its own.
    /// </summary>
    public static DisplayRect? Box(PdfDocument document, StructElement figure, int page)
    {
        if (page < 0 || page >= document.Pages.Count) return null;
        var owned = new HashSet<(int Stream, int Mcid)>();
        var pending = new Stack<StructElement>([figure]);
        int budget = 2000;
        while (pending.Count > 0 && budget-- > 0)
        {
            foreach (var kid in pending.Pop().Kids)
            {
                if (kid is StructContent content && content.PageIndex == page) owned.Add((content.Stream?.Number ?? 0, content.Mcid));
                else if (kid is StructElement child) pending.Push(child);
            }
        }
        if (owned.Count == 0) return null;

        var finder = new Finder(owned);
        try
        {
            new ContentInterpreter(document).Run(document.Pages[page], finder);
        }
        catch (PdfReadException)
        {
        }
        var box = finder.Pictures ?? finder.Drawing;
        if (box is not { } found) return null;
        return new PageGeometry(document.Pages[page]).ToDisplay(found);
    }

    private sealed class Finder(HashSet<(int Stream, int Mcid)> owned) : ContentVisitor
    {
        private readonly List<(MarkedContent Mark, int Stream)> _open = [];

        public PdfRect? Pictures { get; private set; }

        public PdfRect? Drawing { get; private set; }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (Owns()) Pictures = Join(Pictures, image.Bounds);
        }

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (!path.Clips && Owns()) Drawing = Join(Drawing, path.InkBounds);
        }

        // A sequence is numbered in the stream that holds its BDC, which can enclose the form being drawn.
        public override void BeginMarked(ContentContext context, MarkedContent marked) =>
            _open.Add((marked, context.Forms.Count > 0 ? context.Forms[^1].Number : 0));

        public override void EndMarked(ContentContext context, MarkedContent marked) => _open.RemoveAt(_open.Count - 1);

        private bool Owns()
        {
            for (int i = _open.Count - 1; i >= 0; i--)
            {
                if (_open[i].Mark.Mcid is { } mcid) return owned.Contains((_open[i].Stream, mcid));
            }
            return false;
        }

        private static PdfRect Join(PdfRect? so, PdfRect box) =>
            so is { } a ? new PdfRect(Math.Min(a.Left, box.Left), Math.Min(a.Bottom, box.Bottom), Math.Max(a.Right, box.Right), Math.Max(a.Top, box.Top)) : box;
    }
}
