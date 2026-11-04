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
            if (!_pages.TryGetValue(content.PageIndex, out var pieces)) _pages[content.PageIndex] = pieces = Read(document, document.Pages[content.PageIndex]);
            if (pieces.TryGetValue((content.Stream?.Number ?? 0, content.Mcid), out var piece)) into.Append(piece.Text).Append(' ');
        }

        // Characters by the sequence that holds them; a sequence of the page also takes what its forms draw.
        private static Dictionary<(int Stream, int Mcid), Piece> Read(PdfDocument document, PdfPage page)
        {
            var text = TextPage.Create(document, page);
            var pieces = new Dictionary<(int, int), Piece>();
            var chars = text.Chars;
            for (int i = 0; i < chars.Count; i++)
            {
                var c = chars[i];
                int? mcid = c.Mcid;
                if (mcid is null && c.IsImplied && i > 0 && i + 1 < chars.Count && chars[i - 1].Mcid is { } before && chars[i + 1].Mcid == before) mcid = before;
                if (mcid is not { } id) continue;
                Add(pieces, (0, id), c);
                if (c.Form is { } form) Add(pieces, (form.Number, id), c);
            }
            return pieces;
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
