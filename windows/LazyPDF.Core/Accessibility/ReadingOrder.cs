using System.Text;

namespace LazyPDF.Core;

/// <summary>The text a screen reader would meet, in the order the tags give it.</summary>
public static class ReadingOrder
{
    private static readonly HashSet<string> Inline = ["Span", "Link", "Quote", "Code", "Reference", "Note", "BibEntry", "Em", "Strong", "Sub", "Ruby", "Warichu"];

    private sealed class Piece
    {
        public StringBuilder Text { get; } = new();
        public int Line { get; set; } = -1;
    }

    /// <summary>
    /// One line per block: headings after as many <c>#</c> as their level, a list item with its label,
    /// a table row with its cells apart by tabs, a figure as <c>[Figure: alt text]</c>. Artifacts are not
    /// in the tags and so not here. Empty when the document has no tags; pass <paramref name="tree"/>
    /// to use one already read.
    /// </summary>
    public static string Export(PdfDocument document, StructureTree? tree = null)
    {
        tree ??= StructureTree.Read(document);
        if (tree is null) return "";
        var walker = new Walker(document, tree);
        foreach (var root in tree.Roots) walker.Visit(root);
        return walker.Result();
    }

    private sealed class Walker(PdfDocument document, StructureTree tree)
    {
        private readonly Dictionary<int, Dictionary<(int Stream, int Mcid), Piece>> _pages = [];
        private readonly HashSet<(int Page, int Stream, int Mcid)> _named = tree.Contents.Select(c => (c.PageIndex, c.Stream?.Number ?? 0, c.Mcid)).ToHashSet();
        private readonly List<string> _lines = [];
        private readonly StringBuilder _line = new();

        public string Result() => string.Join('\n', _lines);

        public void Visit(StructElement element)
        {
            string type = tree.StandardType(element.Type);
            switch (type)
            {
                case "Figure":
                    Flush();
                    string alt = !string.IsNullOrWhiteSpace(element.Alt) ? element.Alt.Trim() : Everything(element);
                    _lines.Add(alt.Length > 0 ? $"[{AccessibilityText.FigureLabel}: {alt}]" : $"[{AccessibilityText.FigureLabel}]");
                    return;
                case "TR":
                    Flush();
                    _lines.Add(string.Join('\t', element.Children.Select(Everything)));
                    return;
                case "LI":
                    Flush();
                    _lines.Add(Everything(element));
                    return;
            }

            Flush();
            if (type.Length == 2 && type[0] == 'H' && char.IsDigit(type[1])) _line.Append(new string('#', type[1] - '0')).Append(' ');
            foreach (var kid in element.Kids)
            {
                if (kid is StructContent content) Append(_line, content);
                else if (kid is StructElement child && Inline.Contains(tree.StandardType(child.Type))) _line.Append(Everything(child));
                else if (kid is StructElement block)
                {
                    Flush();
                    Visit(block);
                }
            }
            Flush();
        }

        private void Flush()
        {
            string text = string.Join(' ', _line.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            _line.Clear();
            if (text.Length > 0 && !text.All(c => c == '#')) _lines.Add(text);
        }

        // The element's own words: its content and everything below it, in order.
        private string Everything(StructElement element)
        {
            var text = new StringBuilder();
            var stack = new Stack<StructKid>(element.Kids.Reverse());
            int budget = 100_000;
            while (stack.Count > 0 && --budget > 0)
            {
                switch (stack.Pop())
                {
                    case StructContent content:
                        Append(text, content);
                        break;
                    case StructElement child:
                        if (tree.StandardType(child.Type) != "Figure" && text.Length > 0 && text[^1] != ' ') text.Append(' ');
                        foreach (var kid in child.Kids.Reverse()) stack.Push(kid);
                        break;
                }
            }
            return string.Join(' ', text.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        }

        private void Append(StringBuilder into, StructContent content)
        {
            if (content.PageIndex < 0 || content.PageIndex >= document.Pages.Count) return;
            if (!_pages.TryGetValue(content.PageIndex, out var pieces)) _pages[content.PageIndex] = pieces = Read(document.Pages[content.PageIndex]);
            if (pieces.TryGetValue((content.Stream?.Number ?? 0, content.Mcid), out var piece)) into.Append(piece.Text).Append(' ');
        }

        // Characters by the sequence that holds them: the innermost one around the glyph that the tree names, each in the stream that numbers it.
        private Dictionary<(int Stream, int Mcid), Piece> Read(PdfPage page)
        {
            var text = TextPage.Create(document, page);
            var owners = new Owners(_named.Contains, page.Index);
            try
            {
                new ContentInterpreter(document) { WalkPatterns = false }.Run(page, owners);
            }
            catch (PdfReadException)
            {
            }
            var pieces = new Dictionary<(int, int), Piece>();
            var chars = text.Chars;
            var keys = new (int, int)?[chars.Count];
            for (int i = 0; i < chars.Count; i++)
            {
                var c = chars[i];
                if (!c.IsImplied) keys[i] = owners.OwnerOf(c);
            }
            for (int i = 0; i < chars.Count; i++)
            {
                if (chars[i].IsImplied && i > 0 && i + 1 < chars.Count) keys[i] = keys[i - 1] is { } before && keys[i + 1] == before ? before : null;
                if (keys[i] is { } found) Add(pieces, found, chars[i]);
            }
            return pieces;
        }

        // Finds, for each glyph the page draws, the innermost open sequence the tree names; a sequence is numbered in the stream that holds its BDC.
        private sealed class Owners(Func<(int Page, int Stream, int Mcid), bool> named, int page) : ContentVisitor
        {
            private readonly List<(MarkedContent Mark, int Stream)> _open = [];

            // A form drawn twice shows the same operator and offset twice, so the drawings are told apart by where they put the glyph.
            private readonly Dictionary<(int Stream, int Op, int Element, int Offset), List<(double X, double Y, (int Stream, int Mcid)? Owner)>> _glyphs = [];

            public (int Stream, int Mcid)? OwnerOf(TextChar c)
            {
                if (!_glyphs.TryGetValue((c.Form?.Number ?? 0, c.OperatorIndex, c.Element, c.Offset), out var drawn)) return null;
                var (x, y) = (c.Quad.X0, c.Quad.Y0);
                return drawn.MinBy(d => (d.X - x) * (d.X - x) + (d.Y - y) * (d.Y - y)).Owner;
            }

            public override void BeginMarked(ContentContext context, MarkedContent marked) =>
                _open.Add((marked, context.Forms.Count > 0 ? context.Forms[^1].Number : 0));

            public override void EndMarked(ContentContext context, MarkedContent marked) => _open.RemoveAt(_open.Count - 1);

            public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
            {
                (int, int)? owner = null;
                for (int i = _open.Count - 1; i >= 0 && owner is null; i--)
                {
                    if (_open[i].Mark.Mcid is { } mcid && named((page, _open[i].Stream, mcid))) owner = (_open[i].Stream, mcid);
                }
                var key = (context.Forms.Count > 0 ? context.Forms[^1].Number : 0, context.OperatorIndex, glyph.Element, glyph.Offset);
                if (!_glyphs.TryGetValue(key, out var drawn)) _glyphs[key] = drawn = [];
                drawn.Add((glyph.Matrix.E, glyph.Matrix.F, owner));
            }
        }

        private static void Add(Dictionary<(int, int), Piece> pieces, (int, int) key, TextChar c)
        {
            if (!pieces.TryGetValue(key, out var piece)) pieces[key] = piece = new Piece();
            if (piece.Line >= 0 && piece.Line != c.Line && piece.Text.Length > 0 && piece.Text[^1] != ' ') piece.Text.Append(' ');
            piece.Line = c.Line;
            piece.Text.Append(c.Text);
        }
    }
}
