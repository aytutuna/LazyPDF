using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// The text of one page: characters with their places, grouped into words, lines and blocks in
/// reading order. Built from the page's content by <see cref="ContentInterpreter"/>; the result
/// never changes and can be shared between threads. Coordinates are page user space, as in the content.
/// </summary>
public sealed partial class TextPage
{
    private readonly TextChar[] _chars;
    private readonly TextWord[] _words;
    private readonly PageLine[] _lines;
    private readonly TextBlock[] _blocks;
    private readonly PageGeometry _geometry;
    private (double Top, double Bottom)? _extent;
    private string? _text;

    private TextPage(int pageIndex, PdfRect box, PageGeometry geometry, TextChar[] chars, TextWord[] words, PageLine[] lines, TextBlock[] blocks, bool truncated)
    {
        PageIndex = pageIndex;
        Box = box;
        _geometry = geometry;
        _chars = chars;
        _words = words;
        _lines = lines;
        _blocks = blocks;
        IsTruncated = truncated;
    }

    public int PageIndex { get; }

    /// <summary>The crop box of the page.</summary>
    public PdfRect Box { get; }

    /// <summary>The page ran past the interpreter's operation limit or 1,000,000 glyphs; the text stops there.</summary>
    public bool IsTruncated { get; }

    /// <summary>Built with <see cref="TextPageOptions.IncludeAnnotations"/>: some characters belong to appearance streams, and their operator indexes mean nothing in the page's own content.</summary>
    public bool IncludesAnnotations { get; private init; }

    /// <summary>For code that edits the content by operator index.</summary>
    internal void RequirePageContent()
    {
        if (IncludesAnnotations) throw new InvalidOperationException(TextPageText.AnnotationsIncluded);
    }

    public IReadOnlyList<TextChar> Chars => _chars;
    public IReadOnlyList<TextWord> Words => _words;
    public IReadOnlyList<PageLine> Lines => _lines;
    public IReadOnlyList<TextBlock> Blocks => _blocks;

    /// <summary>The whole page as text: lines separated by a line feed, blocks by a blank line, table cells by a tab.</summary>
    public string Text => _text ??= GetText(new TextRange(0, _chars.Length));

    public static TextPage Create(PdfDocument document, PdfPage page, TextPageOptions? options = null) =>
        Create(new ContentInterpreter(document), page, options);

    /// <summary>As above with an interpreter the caller keeps, which saves it parsing fonts again for the next page.</summary>
    public static TextPage Create(ContentInterpreter interpreter, PdfPage page, TextPageOptions? options = null)
    {
        options ??= new TextPageOptions();
        var collector = new TextCollector(options);
        bool truncated = false;
        bool walk = interpreter.WalkPatterns;
        try
        {
            interpreter.WalkPatterns = false;
            interpreter.Run(page, collector);
            truncated = interpreter.IsTruncated;
            if (options.IncludeAnnotations)
            {
                foreach (var (form, matrix) in PageAppearances.Of(interpreter.Document, page, shownOnly: true))
                {
                    // Each run starts with a fresh operation budget, so one that ran out ends the walk.
                    if (truncated || collector.IsFull) break;
                    interpreter.Run(form, collector, matrix);
                    truncated |= interpreter.IsTruncated;
                }
            }
        }
        catch (PdfReadException)
        {
        }
        finally
        {
            interpreter.WalkPatterns = walk;
        }
        truncated |= collector.IsFull;
        if (options.RemoveDuplicates) collector.RemoveDuplicates();
        var geometry = new PageGeometry(page);
        var lines = new TextFlow(geometry).Run(collector.Glyphs);
        return Assemble(page, geometry, lines, truncated, options.IncludeAnnotations);
    }

    private static TextPage Assemble(PdfPage page, PageGeometry geometry, List<FlowLine> layout, bool truncated, bool annotations)
    {
        var chars = new List<TextChar>();
        var words = new List<TextWord>();
        var lines = new List<PageLine>();
        var blocks = new List<TextBlock>();
        int blockFirst = 0;
        for (int li = 0; li < layout.Count; li++)
        {
            var o = layout[li];
            int first = chars.Count;
            foreach (var g in o.Glyphs)
            {
                chars.Add(new TextChar
                {
                    Index = chars.Count,
                    Text = g.Text,
                    Quad = g.Quad,
                    Font = g.Font,
                    Size = g.Size,
                    Color = g.Color,
                    RenderMode = g.Mode,
                    OperatorIndex = g.Op,
                    Form = g.Form,
                    Element = g.Element,
                    Offset = g.Offset,
                    Mcid = g.Mcid,
                    IsArtifact = g.Artifact,
                    IsSpace = g.Space,
                    IsImplied = g.Implied,
                    IsRtl = (g.Level & 1) == 1,
                    Line = li,
                });
            }
            AddWords(chars, first, li, words);
            var box = new QuadBox();
            var text = new StringBuilder();
            for (int i = first; i < chars.Count; i++)
            {
                box.Add(chars[i].Quad);
                text.Append(chars[i].Text);
            }
            var quad = box.ToQuad();
            lines.Add(new PageLine(li, new TextRange(first, chars.Count), text.ToString(), quad.Bounds, quad, blocks.Count, o.Before, o.Vertical, o.Rtl));
            if (li + 1 == layout.Count || layout[li + 1].Block != o.Block)
            {
                var range = new TextRange(blockFirst, li + 1);
                var bounds = lines[blockFirst].Bounds;
                for (int k = blockFirst + 1; k <= li; k++) bounds = Union(bounds, lines[k].Bounds);
                blocks.Add(new TextBlock(blocks.Count, range, bounds, o.Table));
                blockFirst = li + 1;
            }
        }
        return new TextPage(page.Index, page.CropBox, geometry, [.. chars], [.. words], [.. lines], [.. blocks], truncated) { IncludesAnnotations = annotations };
    }

    private static void AddWords(List<TextChar> chars, int first, int line, List<TextWord> words)
    {
        int start = -1;
        for (int i = first; i <= chars.Count; i++)
        {
            bool space = i == chars.Count || chars[i].IsSpace;
            if (!space)
            {
                if (start < 0) start = i;
                continue;
            }
            if (start < 0) continue;
            var text = new StringBuilder();
            var bounds = chars[start].Quad.Bounds;
            for (int k = start; k < i; k++)
            {
                text.Append(chars[k].Text);
                chars[k].Word = words.Count;
                bounds = Union(bounds, chars[k].Quad.Bounds);
            }
            words.Add(new TextWord(words.Count, new TextRange(start, i), text.ToString(), bounds, line));
            start = -1;
        }
    }

    private static PdfRect Union(PdfRect a, PdfRect b) =>
        new(Math.Min(a.Left, b.Left), Math.Min(a.Bottom, b.Bottom), Math.Max(a.Right, b.Right), Math.Max(a.Top, b.Top));

    /// <summary>
    /// The text of a run of characters. White space at the ends of lines is dropped. With
    /// <paramref name="joinHyphens"/> a hyphen that ends a line and follows a letter is taken out and
    /// the line is joined to the next one; a hyphen before a capital stays (a compound name).
    /// </summary>
    public string GetText(TextRange range, bool joinHyphens = false)
    {
        int start = Math.Clamp(range.Start, 0, _chars.Length), end = Math.Clamp(range.End, start, _chars.Length);
        var sb = new StringBuilder();
        var pending = new StringBuilder();
        int line = -1;
        bool atStart = true;
        for (int i = start; i < end; i++)
        {
            var c = _chars[i];
            if (c.Line != line)
            {
                pending.Clear();
                if (line >= 0 && sb.Length > 0 && !c.IsSpace)
                {
                    var before = _lines[c.Line].Before;
                    if (!(joinHyphens && before == TextBreak.Line && TryJoin(sb, c))) sb.Append(Separator(before));
                }
                line = c.Line;
                atStart = true;
            }
            if (c.IsSpace)
            {
                if (!atStart) pending.Append(c.Text);
                continue;
            }
            if (c.Text.Length == 0) continue;
            if (c.Text == "\u00AD" && i + 1 < end && _chars[i + 1].Line == line) continue;
            sb.Append(pending).Append(c.Text);
            pending.Clear();
            atStart = false;
        }
        return sb.ToString();
    }

    private static string Separator(TextBreak before) => before switch
    {
        TextBreak.Tab => "\t",
        TextBreak.Line => "\n",
        TextBreak.Block => "\n\n",
        _ => "",
    };

    private static bool TryJoin(StringBuilder sb, TextChar next)
    {
        if (sb.Length < 2 || next.Text.Length == 0) return false;
        char hyphen = sb[^1];
        if (hyphen is not ('-' or '\u00AD' or '\u2010' or '\u2011') || !char.IsLetter(sb[^2]) || !char.IsLetter(next.Text[0])) return false;
        if (hyphen == '\u00AD' || char.IsLower(next.Text[0])) sb.Length--;
        return true;
    }

    /// <summary>
    /// The boxes that cover a run of characters, one for each stretch of a line without a break in
    /// it, for painting a selection or a search hit. Spaces at the ends of a stretch are left out.
    /// </summary>
    public IReadOnlyList<TextQuad> Quads(TextRange range)
    {
        int start = Math.Clamp(range.Start, 0, _chars.Length), end = Math.Clamp(range.End, start, _chars.Length);
        var result = new List<TextQuad>();
        var box = new QuadBox();
        int pendingFrom = -1;
        TextChar? previous = null;
        void Flush()
        {
            if (!box.IsEmpty) result.Add(box.ToQuad());
            box = new QuadBox();
            pendingFrom = -1;
            previous = null;
        }
        for (int i = start; i < end; i++)
        {
            var c = _chars[i];
            if (previous is not null && (c.Line != previous.Line || previous.Quad.DistanceTo(c.Quad.Center.X, c.Quad.Center.Y) > c.Size)) Flush();
            if (c.IsSpace)
            {
                if (!box.IsEmpty && pendingFrom < 0) pendingFrom = i;
                previous = c;
                continue;
            }
            if (pendingFrom >= 0)
            {
                for (int k = pendingFrom; k < i; k++) box.Add(_chars[k].Quad);
                pendingFrom = -1;
            }
            box.Add(c.Quad);
            previous = c;
        }
        Flush();
        return result;
    }

    /// <summary>The characters of a word.</summary>
    public TextRange WordRange(int word) => _words[word].Range;

    public TextRange LineRange(int line) => _lines[line].Range;
}
