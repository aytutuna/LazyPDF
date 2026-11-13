namespace LazyPDF.Core;

// What the pages draw: tagged or artifact (7.1), fonts (7.21) and XObjects (7.20), found in one run of the interpreter per page.
internal sealed partial class PdfUaChecker
{
    // What a page's content says about itself.
    private sealed class PageContent(Func<PdfStream?, int, bool>? known) : ContentVisitor
    {
        private readonly List<(MarkedContent Mark, PdfStream? Form)> _open = [];

        public int Untagged { get; private set; }
        public int ArtifactInTagged { get; private set; }
        public int TaggedInArtifact { get; private set; }
        public Dictionary<PdfFont, (bool Shown, bool NoText)> Fonts { get; } = new(ReferenceEqualityComparer.Instance);

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (glyph.Character.IsSpace) return;
            Fonts.TryGetValue(glyph.Font, out var use);
            Fonts[glyph.Font] = (use.Shown || context.State.RenderMode != 3, use.NoText || string.IsNullOrEmpty(glyph.Unicode));
            Note();
        }

        public override void PaintImage(ContentContext context, ImageInfo image) => Note();

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke) Note();
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading) => Note();

        // A sequence is numbered in the stream that holds it, so each is kept with its form.
        public override void BeginMarked(ContentContext context, MarkedContent marked) =>
            _open.Add((marked, context.Forms.Count > 0 ? context.Forms[^1] : null));

        public override void EndMarked(ContentContext context, MarkedContent marked) => _open.RemoveAt(_open.Count - 1);

        private void Note()
        {
            int artifact = _open.FindIndex(o => o.Mark.Tag == "Artifact");
            int tagged = _open.FindIndex(o => o.Mark.Mcid is { } mcid && (known is null || known(o.Form, mcid)));
            if (artifact < 0 && tagged < 0) Untagged++;
            else if (artifact >= 0 && tagged >= 0)
            {
                if (artifact > tagged) ArtifactInTagged++;
                else TaggedInArtifact++;
            }
        }
    }

    private void CheckContent()
    {
        var inPage = new Dictionary<int, HashSet<int>>();
        var inForm = new HashSet<(int Stream, int Mcid)>();
        foreach (var content in _tree?.Contents ?? [])
        {
            if (content.Stream is { } stream) inForm.Add((stream.Number, content.Mcid));
            else
            {
                if (!inPage.TryGetValue(content.PageIndex, out var set)) inPage[content.PageIndex] = set = [];
                set.Add(content.Mcid);
            }
        }

        var interpreter = new ContentInterpreter(_doc) { WalkPatterns = false };
        var fonts = new Dictionary<PdfFont, (bool Shown, bool NoText)>(ReferenceEqualityComparer.Instance);
        foreach (var page in _doc.Pages)
        {
            cancel.ThrowIfCancellationRequested();
            bool Known(PdfStream? form, int mcid) =>
                form is null ? inPage.TryGetValue(page.Index, out var set) && set.Contains(mcid) : inForm.Contains((form.Number, mcid));

            var visitor = new PageContent(_tree is null ? null : Known);
            try
            {
                interpreter.Run(page, visitor);
            }
            catch (PdfReadException)
            {
                continue;
            }
            string where = PdfAText.PageName(page.Index + 1);
            if (_tree is not null && visitor.Untagged > 0) Add("01-003", "7.1", where, PdfUaText.Untagged);
            if (visitor.ArtifactInTagged > 0) Add("01-004", "7.1", where, PdfUaText.ArtifactInTagged);
            if (visitor.TaggedInArtifact > 0) Add("01-005", "7.1", where, PdfUaText.TaggedInArtifact);
            foreach (var (font, use) in visitor.Fonts)
            {
                fonts.TryGetValue(font, out var before);
                fonts[font] = (before.Shown || use.Shown, before.NoText || use.NoText);
            }
        }

        // 7.21.3 and 7.21.4: a font that shows text is embedded (a font used only invisibly is exempt) and maps to Unicode.
        foreach (var (font, use) in fonts)
        {
            string where = PdfAText.FontName(font.BaseFont);
            if (use.Shown && !font.IsEmbedded && !font.IsType3) Add("31-001", "7.21.4.1", where, PdfUaText.FontNotEmbedded);
            if (use.NoText) Add("31-008", "7.21.7", where, PdfUaText.FontNoUnicode);
        }
    }

    // 7.20: no reference or PostScript XObject, in a page's resources or in the forms below them.
    private void CheckXObjects()
    {
        var seen = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        var pending = new Stack<(PdfDictionary? Resources, string Where)>();
        foreach (var page in _doc.Pages) pending.Push((page.Resources, PdfAText.PageName(page.Index + 1)));
        while (pending.Count > 0 && seen.Count < MaxEntries)
        {
            var (resources, where) = pending.Pop();
            if (_doc.Dict(resources, "XObject") is not { } xobjects) continue;
            foreach (var (_, value) in xobjects.Entries.Take(MaxEntries))
            {
                if (_doc.Resolve(value) is not PdfStream xobject || !seen.Add(xobject)) continue;
                string? subtype = _doc.Name(xobject.Dictionary, "Subtype");
                if (subtype == "PS" || xobject.Dictionary.ContainsKey("PS")) Add("30-002", "7.20", where, PdfUaText.PostScriptXObject);
                if (xobject.Dictionary.ContainsKey("Ref")) Add("30-001", "7.20", where, PdfUaText.ReferenceXObject);
                if (subtype == "Form") pending.Push((_doc.Dict(xobject.Dictionary, "Resources"), where));
            }
        }
    }
}
