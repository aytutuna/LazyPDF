namespace LazyPDF.Core;

/// <summary>Where a piece of an element's content is on a page, in the page's user space (before /Rotate).</summary>
public sealed record ElementBox(int PageIndex, PdfRect Rect);

/// <summary>The boxes of an element's content in tree order; <see cref="IsCapped"/> when the element had more than was looked at.</summary>
public sealed record ElementBoxes(IReadOnlyList<ElementBox> Boxes, bool IsCapped);

public sealed partial class StructureTree
{
    private const int MaxBoxKids = 20_000;
    private const int MaxBoxPages = 100;
    private const int MaxBoxes = 500;

    /// <summary>
    /// The page rectangles of the marked content under <paramref name="element"/>, for showing it on the page: one box
    /// per sequence, around what the sequence draws (the page's own content and form XObjects drawn there), and the
    /// /Rect of each annotation the element holds. A sequence that draws nothing has no box. The walk stops at
    /// 20 000 kids, 100 pages and 500 boxes, and says so.
    /// </summary>
    public ElementBoxes Boxes(StructElement element)
    {
        bool capped = false;
        var wanted = new List<StructKid>();
        foreach (var e in Subtree(element))
        {
            foreach (var kid in e.KidList)
            {
                if (kid is StructElement) continue;
                if (wanted.Count >= MaxBoxKids) capped = true;
                else wanted.Add(kid);
            }
        }

        var drawn = new Dictionary<(int Page, int Stream, int Mcid), PdfRect>();
        var pages = wanted.OfType<StructContent>().Select(c => c.PageIndex).Where(p => p >= 0 && p < _document.Pages.Count).Distinct().ToList();
        if (pages.Count > MaxBoxPages)
        {
            capped = true;
            pages = pages[..MaxBoxPages];
        }
        foreach (int page in pages)
        {
            var keys = wanted.OfType<StructContent>().Where(c => c.PageIndex == page).Select(c => (c.Stream?.Number ?? 0, c.Mcid)).ToHashSet();
            var boxer = new Boxer(keys);
            try
            {
                new ContentInterpreter(_document) { WalkPatterns = false }.Run(_document.Pages[page], boxer);
            }
            catch (PdfReadException)
            {
            }
            foreach (var (key, rect) in boxer.Found) drawn[(page, key.Stream, key.Mcid)] = rect;
        }

        var boxes = new List<ElementBox>();
        foreach (var kid in wanted)
        {
            PdfRect? rect = kid switch
            {
                StructContent c when drawn.TryGetValue((c.PageIndex, c.Stream?.Number ?? 0, c.Mcid), out var found) => found,
                StructObject o => _document.Rect(_document.Resolve(o.Target) as PdfDictionary, "Rect"),
                _ => null,
            };
            if (rect is null) continue;
            if (boxes.Count >= MaxBoxes)
            {
                capped = true;
                break;
            }
            boxes.Add(new ElementBox(kid is StructContent content ? content.PageIndex : ((StructObject)kid).PageIndex, rect.Value));
        }
        return new ElementBoxes(boxes, capped);
    }

    // What a sequence draws goes to the innermost /MCID sequence around it, the way ReadingOrder gives a glyph an owner.
    private sealed class Boxer(HashSet<(int Stream, int Mcid)> keys) : ContentVisitor
    {
        private readonly List<(int Stream, int? Mcid)> _open = [];

        public Dictionary<(int Stream, int Mcid), PdfRect> Found { get; } = [];

        public override void BeginMarked(ContentContext context, MarkedContent marked) =>
            _open.Add((context.Forms.Count > 0 ? context.Forms[^1].Number : 0, marked.Mcid));

        public override void EndMarked(ContentContext context, MarkedContent marked) => _open.RemoveAt(_open.Count - 1);

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => Add(glyph.Bounds);

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke) Add(path.InkBounds);
        }

        public override void PaintImage(ContentContext context, ImageInfo image) => Add(image.Bounds);

        private void Add(PdfRect bounds)
        {
            for (int i = _open.Count - 1; i >= 0; i--)
            {
                if (_open[i].Mcid is not { } mcid) continue;
                var key = (_open[i].Stream, mcid);
                if (keys.Contains(key))
                {
                    Found[key] = Found.TryGetValue(key, out var have) ? new PdfRect(Math.Min(have.Left, bounds.Left), Math.Min(have.Bottom, bounds.Bottom), Math.Max(have.Right, bounds.Right), Math.Max(have.Top, bounds.Top)) : bounds;
                }
                return;
            }
        }
    }
}
