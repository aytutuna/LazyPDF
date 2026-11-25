namespace LazyPDF.Core;

public static partial class AccessibilityChecker
{
    private sealed record ContentChecks(AccessibilityItem Searchable, AccessibilityItem Encoding, AccessibilityItem TaggedContent);

    // What a page's content says about itself, found in one run of the interpreter.
    private sealed class PageContent(Func<PdfStream?, int, bool> known) : ContentVisitor
    {
        private readonly List<(MarkedContent Mark, PdfStream? Form)> _open = [];

        public int Glyphs { get; private set; }
        public int Images { get; private set; }
        public int Loose { get; private set; }
        public Dictionary<string, int> FontsWithoutText { get; } = [];

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (glyph.Character.IsSpace) return;
            Glyphs++;
            // 7.21.7 of ISO 14289-1: every character maps to Unicode.
            if (string.IsNullOrEmpty(glyph.Unicode))
            {
                FontsWithoutText[glyph.Font.Name] = FontsWithoutText.GetValueOrDefault(glyph.Font.Name) + 1;
            }
            Note(context);
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            Images++;
            Note(context);
        }

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke) Note(context);
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading) => Note(context);

        // A sequence is numbered in the stream that holds it, so each is kept with its form.
        public override void BeginMarked(ContentContext context, MarkedContent marked) =>
            _open.Add((marked, context.Forms.Count > 0 ? context.Forms[^1] : null));

        public override void EndMarked(ContentContext context, MarkedContent marked) => _open.RemoveAt(_open.Count - 1);

        // 7.1 of ISO 14289-1: everything drawn is in the tags or an artifact.
        private void Note(ContentContext context)
        {
            if (context.Marked.Any(m => m.Tag == "Artifact")) return;
            if (!_open.Any(o => o.Mark.Mcid is { } mcid && known(o.Form, mcid))) Loose++;
        }
    }

    /// <summary>The tagged-content rule alone, for the PDF/A level A checks.</summary>
    internal static AccessibilityItem TaggedContent(PdfDocument document, StructureTree tree) => ReadContent(document, tree, default).TaggedContent;

    private static ContentChecks ReadContent(PdfDocument document, StructureTree? tree, CancellationToken cancel)
    {
        var inPage = new Dictionary<int, HashSet<int>>();
        var inForm = new HashSet<(int Stream, int Mcid)>();
        foreach (var content in tree?.Contents ?? [])
        {
            if (content.Stream is { } stream) inForm.Add((stream.Number, content.Mcid));
            else
            {
                if (!inPage.TryGetValue(content.PageIndex, out var set)) inPage[content.PageIndex] = set = [];
                set.Add(content.Mcid);
            }
        }

        var interpreter = new ContentInterpreter(document) { WalkPatterns = false };
        var imageOnly = new Found();
        var fonts = new Found();
        var loose = new Found();
        var seenFonts = new HashSet<string>();
        foreach (var page in document.Pages)
        {
            cancel.ThrowIfCancellationRequested();
            // Without a tree every sequence counts as known: the tagged rule is then a person's to judge.
            bool Known(PdfStream? form, int mcid) =>
                tree is null || (form is null ? inPage.TryGetValue(page.Index, out var set) && set.Contains(mcid) : inForm.Contains((form.Number, mcid)));

            var visitor = new PageContent(Known);
            try
            {
                interpreter.Run(page, visitor);
            }
            catch (PdfReadException)
            {
                continue;
            }
            if (visitor.Images > 0 && visitor.Glyphs == 0) imageOnly.Add(page.Index, page.Reference);
            foreach (string font in visitor.FontsWithoutText.Keys)
            {
                if (seenFonts.Add(font)) fonts.Add(page.Index, page.Reference);
            }
            if (visitor.Loose > 0) loose.Add(page.Index, page.Reference);
        }

        return new ContentChecks(
            imageOnly.Count == 0 ? Pass(AccessibilityRule.Searchable) : Fail(AccessibilityRule.Searchable, imageOnly),
            fonts.Count == 0 ? Pass(AccessibilityRule.Encoding) : Fail(AccessibilityRule.Encoding, fonts),
            tree is null ? NoTags(AccessibilityRule.TaggedContent)
                : loose.Count == 0 ? Pass(AccessibilityRule.TaggedContent) : Fail(AccessibilityRule.TaggedContent, loose));
    }
}
