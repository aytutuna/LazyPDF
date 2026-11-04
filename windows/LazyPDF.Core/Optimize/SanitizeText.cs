namespace LazyPDF.Core;

// Text a reader cannot see: white on a page that is blank under it, or covered by a picture
// painted later (reported only), and text in render mode 3, which may be an OCR layer and goes
// only on request.
internal sealed class SanitizeText(PdfDocument document)
{
    private const int MaxGlyphs = 100_000;
    private const int MaxPaints = 20_000;
    private const byte Light = 247;

    private readonly record struct Glyph(object Run, PdfRect Bounds, bool White, int Mode, int Order);

    private readonly record struct Paint(PdfRect Bounds, bool Light, bool Image, int Order);

    private sealed class Scan : ContentVisitor
    {
        public readonly List<Glyph> Glyphs = [];
        public readonly List<Paint> Paints = [];
        private int _order;

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (Glyphs.Count >= MaxGlyphs) return;
            var state = context.State;
            var color = state.RenderMode == 1 ? state.StrokeColor : state.FillColor;
            var rgb = color.Rgb;
            bool white = rgb.R >= Light && rgb.G >= Light && rgb.B >= Light;
            Glyphs.Add(new Glyph((context.Forms.Count == 0 ? null : context.Forms[^1], context.OperatorIndex), glyph.Bounds, white, state.RenderMode, _order++));
        }

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (!path.Fill || Paints.Count >= MaxPaints) return;
            var rgb = context.State.FillColor.Rgb;
            Paints.Add(new Paint(path.Bounds, rgb.R >= Light && rgb.G >= Light && rgb.B >= Light, false, _order++));
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (Paints.Count < MaxPaints) Paints.Add(new Paint(image.Bounds, false, !image.IsMask && !image.Dictionary.ContainsKey("SMask"), _order++));
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading)
        {
            if (Paints.Count < MaxPaints) Paints.Add(new Paint(shading.Bounds, false, false, _order++));
        }
    }

    /// <summary>The runs of text a reader cannot see (hidden) and the runs in render mode 3 (invisible); a run is one text-showing operator.</summary>
    public (int Hidden, int Invisible) Count()
    {
        var hidden = new HashSet<object>();
        var invisible = new HashSet<object>();
        var interpreter = new ContentInterpreter(document);
        foreach (var page in document.Pages)
        {
            var scan = new Scan();
            interpreter.Run(page, scan);
            var images = scan.Paints.Where(p => p.Image).ToList();
            foreach (var glyph in scan.Glyphs)
            {
                var key = (page.Index, glyph.Run);
                if (glyph.Mode == 3)
                {
                    invisible.Add(key);
                    continue;
                }
                if (glyph.Mode is 4 or 5 or 6 or 7 || hidden.Contains(key)) continue;
                var center = (X: (glyph.Bounds.Left + glyph.Bounds.Right) / 2, Y: (glyph.Bounds.Bottom + glyph.Bounds.Top) / 2);
                bool covered = images.Any(p => p.Order > glyph.Order && Holds(p.Bounds, glyph.Bounds));
                bool blank = !covered && glyph.White && !scan.Paints.Any(p => p.Order < glyph.Order && !p.Light && Contains(p.Bounds, center.X, center.Y));
                if (covered || blank) hidden.Add(key);
            }
        }
        return (hidden.Count, invisible.Count);
    }

    private static bool Contains(PdfRect box, double x, double y) => x >= box.Left && x <= box.Right && y >= box.Bottom && y <= box.Top;

    private static bool Holds(PdfRect outer, PdfRect inner) =>
        inner.Left >= outer.Left - 0.5 && inner.Right <= outer.Right + 0.5 && inner.Bottom >= outer.Bottom - 0.5 && inner.Top <= outer.Top + 0.5;

    /// <summary>Takes the text objects whose every show is in render mode 3 out of pages and forms; returns how many shows went.</summary>
    public int Strip()
    {
        int removed = 0;
        foreach (var page in document.Pages)
        {
            byte[] data = page.Contents();
            if (Rewrite(data) is not { } rebuilt) continue;
            removed += rebuilt.Removed;
            var stream = new PdfStream(new PdfDictionary(), []);
            PdfGraph.SetData(stream, rebuilt.Data);
            page.Dictionary["Contents"] = document.Add(stream);
        }
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            if (value is not PdfStream stream || document.Name(stream.Dictionary, "Subtype") != "Form") continue;
            byte[] data;
            try
            {
                data = document.Data(stream);
            }
            catch (PdfReadException)
            {
                continue;
            }
            if (Rewrite(data) is not { } rebuilt) continue;
            removed += rebuilt.Removed;
            PdfGraph.SetData(stream, rebuilt.Data);
        }
        return removed;
    }

    private static (byte[] Data, int Removed)? Rewrite(byte[] data)
    {
        if (data.AsSpan().IndexOf("Tr"u8) < 0) return null;
        var operations = ContentParser.Parse(data);
        var saved = new Stack<int>();
        int mode = 0;
        var edits = new List<(ContentOperation Op, string Text)>();
        var segment = new List<(ContentOperation Op, int Mode)>();
        bool inText = false;
        foreach (var op in operations)
        {
            switch (op.Operator)
            {
                case "q":
                    saved.Push(mode);
                    break;
                case "Q" when saved.Count > 0:
                    mode = saved.Pop();
                    break;
                case "Tr":
                    if (op.Number(0) is { } m) mode = (int)m;
                    break;
                case "BT":
                    inText = true;
                    segment.Clear();
                    break;
                case "Tj" or "TJ" or "'" or "\"" when inText:
                    segment.Add((op, mode));
                    break;
                case "ET":
                    inText = false;
                    if (segment.Count > 0 && segment.All(s => s.Mode == 3))
                    {
                        foreach (var (shown, _) in segment) edits.Add((shown, Replacement(shown)));
                    }
                    segment.Clear();
                    break;
            }
        }
        if (edits.Count == 0) return null;
        var output = new MemoryStream();
        int position = 0;
        foreach (var (op, text) in edits)
        {
            output.Write(data, position, op.Start - position);
            output.Write(System.Text.Encoding.Latin1.GetBytes(text));
            position = op.End;
        }
        output.Write(data, position, data.Length - position);
        return (output.ToArray(), edits.Count);
    }

    // The line moves of ' and " stay, so text that follows is placed where it was.
    private static string Replacement(ContentOperation op) => op.Operator switch
    {
        "'" => "T*",
        "\"" when op.Operands.Count >= 3 => $"{op.Operands[^3]} Tw {op.Operands[^2]} Tc T*",
        "\"" => "T*",
        _ => "",
    };
}
