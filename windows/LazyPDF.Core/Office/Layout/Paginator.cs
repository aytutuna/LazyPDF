using System.Globalization;

namespace LazyPDF.Core.Office;

/// <summary>
/// Sets a <see cref="LayoutDocument"/> on pages. Sections and page breaks start pages; a paragraph breaks across
/// pages with widow and orphan control; keep-with-next moves a chain of paragraphs together; space before is
/// dropped at the top of a page that a full page ended. Header and footer bands are laid out last, when the
/// page count is known.
/// </summary>
internal sealed partial class Paginator
{
    public const int MaxPages = 10_000;
    private const double Tolerance = 0.01;
    private const double MinArea = 36;

    private sealed class Page(LayoutSection section, PageVariant variant, double top, double bottom, bool hard)
    {
        public LayoutSection Section { get; } = section;
        public PageVariant Variant { get; } = variant;
        public double Top { get; } = top;
        public double Bottom { get; } = bottom;
        public bool Hard { get; } = hard;
        public double Y { get; set; } = top;
        public bool HasContent { get; set; }
        public List<LayoutBox> Boxes { get; } = [];
    }

    private readonly LayoutDocument _document;
    private readonly LayoutFonts _fonts;
    private readonly CancellationToken _cancellation;
    private readonly List<Page> _pages = [];
    private int _rightToLeft, _complex;
    // The body area of each kind of page of the section being laid out, and how many pages it has so far.
    private readonly (double Top, double Bottom)[] _areas = new (double, double)[3];
    private int _sectionPages;

    public Paginator(LayoutDocument document, LayoutFonts fonts, CancellationToken cancellation)
    {
        _document = document;
        _fonts = fonts;
        _cancellation = cancellation;
    }

    public LayoutResult Run()
    {
        if (_document.Sections.Count == 0) throw new ArgumentException("The document has no section.", nameof(_document));
        foreach (var section in _document.Sections) Section(section);

        var pages = new List<LayoutPage>();
        for (int i = 0; i < _pages.Count; i++)
        {
            _cancellation.ThrowIfCancellationRequested();
            var page = _pages[i];
            var geometry = page.Section.Page;
            var boxes = new List<LayoutBox>();
            string number = (i + 1).ToString(CultureInfo.InvariantCulture), total = _pages.Count.ToString(CultureInfo.InvariantCulture);
            var (header, _) = Band(page.Section.HeaderOf(page.Variant), geometry, kind => kind == LayoutField.PageNumber ? number : total);
            var (footer, footerHeight) = Band(page.Section.FooterOf(page.Variant), geometry, kind => kind == LayoutField.PageNumber ? number : total);
            Emit(boxes, header, geometry, geometry.HeaderDistance);
            Emit(boxes, footer, geometry, geometry.Height - geometry.FooterDistance - footerHeight);
            boxes.AddRange(page.Boxes);
            pages.Add(new LayoutPage(geometry.Width, geometry.Height, boxes));
        }
        return new LayoutResult(pages, Skipped(), [.. _fonts.Missing]);
    }

    private List<SkippedFeature> Skipped()
    {
        var all = new List<SkippedFeature>();
        void Add(string kind, int count)
        {
            if (count <= 0) return;
            int at = all.FindIndex(s => s.Kind == kind);
            if (at < 0) all.Add(new SkippedFeature(kind, count));
            else all[at] = all[at] with { Count = all[at].Count + count };
        }
        foreach (var s in _document.Skipped) Add(s.Kind, s.Count);
        Add(SkippedKinds.RightToLeftText, _rightToLeft);
        Add(SkippedKinds.ComplexScript, _complex);
        return all;
    }

    private (List<ParagraphLines> Paragraphs, double Height) Band(List<LayoutParagraph> source, LayoutGeometry geometry, Func<LayoutField, string> field, bool count = false)
    {
        double width = geometry.Width - geometry.Left - geometry.Right, height = 0;
        var paragraphs = new List<ParagraphLines>();
        foreach (var paragraph in source)
        {
            var lines = ParagraphLayout.Run(paragraph, _fonts, width, geometry.Height - geometry.Top - geometry.Bottom, field);
            if (count) Count(lines);
            paragraphs.Add(lines);
            height += paragraph.Before + lines.Height + paragraph.After;
        }
        return (paragraphs, height);
    }

    private void Count(ParagraphLines lines)
    {
        if (lines.RightToLeft) _rightToLeft++;
        if (lines.ComplexScript) _complex++;
    }

    private void Section(LayoutSection section)
    {
        var g = section.Page;
        if (!(g.Width is >= 72 and <= 14400) || !(g.Height is >= 72 and <= 14400) || !(g.Top >= 0) || !(g.Bottom >= 0) || !(g.Left >= 0) || !(g.Right >= 0)
            || g.Width - g.Left - g.Right < MinArea || g.Height - g.Top - g.Bottom < MinArea)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The page size or margins leave no room for text.");
        }
        double width = g.Width - g.Left - g.Right;
        // A band shared by several kinds of page is counted once.
        var counted = new HashSet<List<LayoutParagraph>>(ReferenceEqualityComparer.Instance);
        for (int v = 0; v < 3; v++)
        {
            var variant = (PageVariant)v;
            bool used = variant == PageVariant.Default || (variant == PageVariant.First ? section.TitlePage : section.EvenAndOdd);
            var header = section.HeaderOf(variant);
            var footer = section.FooterOf(variant);
            var (_, headerHeight) = Band(header, g, _ => "1", count: used && counted.Add(header));
            var (_, footerHeight) = Band(footer, g, _ => "1", count: used && counted.Add(footer));
            double top = headerHeight > 0 ? Math.Max(g.Top, g.HeaderDistance + headerHeight) : g.Top;
            double bottom = footerHeight > 0 ? Math.Min(g.Height - g.Bottom, g.Height - g.FooterDistance - footerHeight) : g.Height - g.Bottom;
            // A band that would leave no body gives way to the margins.
            if (bottom - top < MinArea) (top, bottom) = (g.Top, g.Height - g.Bottom);
            _areas[v] = (top, bottom);
        }
        _sectionPages = 0;

        double body = _areas[0].Bottom - _areas[0].Top;
        var blocks = new List<object?>();
        foreach (var block in section.Blocks)
        {
            _cancellation.ThrowIfCancellationRequested();
            if (block is LayoutParagraph paragraph)
            {
                var lines = ParagraphLayout.Run(paragraph, _fonts, width, body);
                Count(lines);
                blocks.Add(lines);
            }
            else if (block is LayoutTable table) blocks.Add(TableLayout.Measure(table, _fonts, width, body, Count));
            else blocks.Add(null);
        }

        NewPage(section, hard: true);
        for (int i = 0; i < blocks.Count; i++)
        {
            _cancellation.ThrowIfCancellationRequested();
            if (blocks[i] is ParagraphLines lines) Place(blocks, i, lines, section);
            else if (blocks[i] is TableLines table) PlaceTable(table, section);
            else NewPage(section, hard: true);
        }
    }

    private void NewPage(LayoutSection section, bool hard)
    {
        if (_pages.Count >= MaxPages) throw new PdfReadException(PdfReadProblem.Unsupported, "The document has too many pages.");
        // The first page of a section and the even pages count by the page's place in the document.
        var variant = section.TitlePage && _sectionPages == 0 ? PageVariant.First
            : section.EvenAndOdd && (_pages.Count + 1) % 2 == 0 ? PageVariant.Even : PageVariant.Default;
        _sectionPages++;
        var (top, bottom) = _areas[(int)variant];
        _pages.Add(new Page(section, variant, top, bottom, hard));
    }

    private void Place(List<object?> blocks, int index, ParagraphLines lines, LayoutSection section)
    {
        var paragraph = lines.Source;
        if (paragraph.PageBreakBefore && _pages[^1].HasContent) NewPage(section, hard: true);
        if (paragraph.KeepWithNext) KeepTogether(blocks, index, section);

        int placed = 0, count = lines.Lines.Count;
        while (placed < count)
        {
            var page = _pages[^1];
            double before = placed == 0 && (page.HasContent || page.Hard) ? paragraph.Before : 0;
            double room = page.Bottom - page.Y - before + Tolerance;
            int fit = 0;
            for (double used = 0; placed + fit < count && used + lines.Lines[placed + fit].Height <= room; fit++) used += lines.Lines[placed + fit].Height;

            int take = fit;
            if (placed + fit < count)
            {
                if (paragraph.WidowControl)
                {
                    if (count - placed - take == 1 && take > 1) take--;
                    if (placed == 0 && take == 1 && page.HasContent) take = 0;
                }
                if (take == 0 && !page.HasContent) take = 1;
                if (take == 0)
                {
                    NewPage(section, hard: false);
                    continue;
                }
            }
            else take = count - placed;

            page.Y += before;
            for (int k = placed; k < placed + take; k++)
            {
                EmitLine(page.Boxes, lines.Lines[k], section.Page.Left, page.Y);
                page.Y += lines.Lines[k].Height;
            }
            page.HasContent = true;
            placed += take;
            if (placed < count) NewPage(section, hard: false);
        }
        _pages[^1].Y += paragraph.After;
    }

    // A chain of keep-with-next paragraphs and the first lines of the one after it move to a fresh page when
    // they would not fit in what is left of this one, if they fit on a page of their own.
    private void KeepTogether(List<object?> blocks, int index, LayoutSection section)
    {
        var page = _pages[^1];
        if (!page.HasContent) return;
        double need = 0;
        int k = index;
        for (; k < blocks.Count && blocks[k] is ParagraphLines { Source.KeepWithNext: true } member; k++)
        {
            need += member.Source.Before + member.Height + member.Source.After;
        }
        if (k < blocks.Count && blocks[k] is ParagraphLines next)
        {
            int lead = Math.Min(next.Lines.Count, next.Source.WidowControl ? 2 : 1);
            need += next.Source.Before + next.Lines.Take(lead).Sum(l => l.Height);
        }
        else if (k < blocks.Count && blocks[k] is TableLines { Rows.Count: > 0 } table) need += table.Rows[0].Height;
        if (need > page.Bottom - page.Y + Tolerance && need <= page.Bottom - page.Top) NewPage(section, hard: false);
    }

    private static void Emit(List<LayoutBox> boxes, List<ParagraphLines> paragraphs, LayoutGeometry geometry, double top)
    {
        double y = top;
        foreach (var paragraph in paragraphs)
        {
            y += paragraph.Source.Before;
            foreach (var line in paragraph.Lines)
            {
                EmitLine(boxes, line, geometry.Left, y);
                y += line.Height;
            }
            y += paragraph.Source.After;
        }
    }

    // Highlights go under the text and underlines and strikes over it. A piece is a stretch of one style;
    // tabs, line breaks and the spaces that end the line draw nothing and split the pieces.
    private static void EmitLine(List<LayoutBox> boxes, LayoutLine line, double originX, double top)
    {
        int ink = line.Atoms.FindLastIndex(a => !a.IsBlank || a.IsTab);
        var under = new List<LayoutBox>();
        var over = new List<LayoutBox>();
        var pictures = new List<LayoutBox>();
        double baseline = top + line.Baseline;
        int from = 0;
        while (from <= ink)
        {
            var first = line.Atoms[from];
            if (first.Picture is { } picture)
            {
                pictures.Add(new PlacedImage(originX + first.X, baseline - first.PictureHeight - first.Run.Shift, first.Width, first.PictureHeight, picture));
                from++;
                continue;
            }
            if (first.IsTab || first.IsNewline || first.IsZeroWidth)
            {
                from++;
                continue;
            }
            int to = from;
            while (to + 1 <= ink && SameStyle(first, line.Atoms[to + 1])) to++;
            var last = line.Atoms[to];
            var text = new System.Text.StringBuilder();
            double extra = 0;
            for (int k = from; k <= to; k++)
            {
                text.Append(char.ConvertFromUtf32(line.Atoms[k].Code));
                if (line.Atoms[k].Extra > 0) extra = line.Atoms[k].Extra;
            }
            var run = first.Run;
            double x = originX + first.X, width = last.X + last.Width + last.Extra - first.X;
            double shift = run.Shift, size = first.Size, bar = size * 0.05;
            if (run.Highlight is { } highlight)
            {
                under.Add(new PlacedRect(x, baseline - shift - first.RunFace.Ascent * size, width, (first.RunFace.Ascent + first.RunFace.Descent) * size, highlight));
            }
            under.Add(new PlacedText(x, baseline - shift, text.ToString(), first.Face.Family, first.Face.Style, size, run.Color, extra));
            if (run.Underline) over.Add(new PlacedRect(x, baseline - shift + size * 0.1, width, bar, run.Color));
            if (run.Strike) over.Add(new PlacedRect(x, baseline - shift - size * 0.3, width, bar, run.Color));
            from = to + 1;
        }
        // The highlights were added with the text; sorted so that every highlight precedes every text of the line.
        boxes.AddRange(under.OfType<PlacedRect>());
        boxes.AddRange(pictures);
        boxes.AddRange(under.OfType<PlacedText>());
        boxes.AddRange(over);
    }

    private static bool SameStyle(Atom a, Atom b) =>
        !b.IsTab && !b.IsNewline && !b.IsZeroWidth && b.Picture is null && a.Face == b.Face && a.Size == b.Size && a.Run.Color == b.Run.Color && a.Run.Underline == b.Run.Underline
        && a.Run.Strike == b.Run.Strike && a.Run.Highlight == b.Run.Highlight && a.Run.Shift == b.Run.Shift;
}
