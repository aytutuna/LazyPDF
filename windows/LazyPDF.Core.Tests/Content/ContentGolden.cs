using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Content/ContentGolden.swift. One line of input is "<op> <words>" (the format is at
// the top of content-input.txt): content streams parsed and written, one-page files run by the interpreter, fonts
// decoding bytes, and the fixture files run, all as text. Numbers go through PdfNumber, which both sides write alike.
internal static class ContentGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            int space = line.IndexOf(' ');
            string op = space < 0 ? line : line[..space];
            string rest = space < 0 ? "" : line[(space + 1)..];
            output.Append("> ").Append(line).Append('\n');
            foreach (string result in Op(op, rest)) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        try
        {
            switch (op)
            {
                case "parse": return Parse(Bytes(rest));
                case "write": return [Golden.Escape(ContentWriter.Write(ContentParser.Parse(Bytes(rest))))];
                case "run": return RunPage(rest);
                case "font": return Fonts(rest);
                case "fixture": return Fixture(rest);
                case "nest": return Nest(int.Parse(rest));
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    // {N*text} is text N times.
    private static string Expand(string text)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '{')
            {
                int j = i + 1;
                while (j < text.Length && text[j] is >= '0' and <= '9') j++;
                int close = text.IndexOf('}', j);
                if (j > i + 1 && j < text.Length && text[j] == '*' && close > j)
                {
                    int count = int.Parse(text.AsSpan(i + 1, j - i - 1));
                    string unit = text[(j + 1)..close];
                    for (int k = 0; k < count; k++) sb.Append(unit);
                    i = close;
                    continue;
                }
            }
            sb.Append(text[i]);
        }
        return sb.ToString();
    }

    private static byte[] Bytes(string text) => Golden.Unescape(Expand(text));

    private static string Latin(string text) => Encoding.Latin1.GetString(Bytes(text));

    private static string N(double v) => new PdfNumber(v).Text;

    private static string M(PdfMatrix m) => $"[{N(m.A)} {N(m.B)} {N(m.C)} {N(m.D)} {N(m.E)} {N(m.F)}]";

    private static string R(PdfRect r) => $"[{N(r.Left)} {N(r.Bottom)} {N(r.Right)} {N(r.Top)}]";

    private static string B(bool value) => value ? "1" : "0";

    private static string U(string? text) =>
        text is null ? "-" : string.Join(",", text.EnumerateRunes().Select(r => r.Value.ToString("X4")));

    private static IEnumerable<string> Parse(byte[] data)
    {
        var lines = new List<string>();
        foreach (var op in ContentParser.Parse(data))
        {
            lines.Add($"op {op.Operator} [{op.Start},{op.End}]" + (op.Operands.Count > 0 ? " " + string.Join(" ", op.Operands) : ""));
            if (op.Image is not { } image) continue;
            lines.Add($"image {image.Data.Length} {Golden.Escape(image.Data)}");
            lines.Add($"dictionary {image.Dictionary}");
            lines.Add($"expanded {image.Expanded()}");
        }
        return lines;
    }

    private static void AddObjects(TestPdf pdf, string[] fields)
    {
        for (int i = 0; i < fields.Length; i++)
        {
            string field = Expand(fields[i]);
            if (!field.StartsWith("stream ", StringComparison.Ordinal))
            {
                pdf.Obj(5 + i, Encoding.Latin1.GetString(Golden.Unescape(field)));
                continue;
            }
            string tail = field[6..];
            int split = tail.IndexOf(" :: ", StringComparison.Ordinal);
            string entries = Encoding.Latin1.GetString(Golden.Unescape(tail[..split])).Trim(' ');
            string data = tail[(split + 4)..];
            byte[] bytes = data.StartsWith("file:", StringComparison.Ordinal)
                ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", data[5..]))
                : Golden.Unescape(data);
            pdf.Stream(5 + i, entries, bytes);
        }
    }

    private static IEnumerable<string> RunPage(string rest)
    {
        string[] fields = rest.Split(" ;; ");
        var document = ContentTestPdf.Page(Golden.Unescape(Expand(fields[1])), Latin(fields[0]), pdf => AddObjects(pdf, fields[2..]));
        return RunAll(document, document.Pages[0]);
    }

    private static IEnumerable<string> Fixture(string rest)
    {
        string[] words = rest.Split(' ');
        byte[] file = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Documents", words[0]));
        var document = PdfDocument.Open(file, words[1] == "-" ? null : words[1]);
        var lines = new List<string>();
        for (int i = 0; i < document.Pages.Count; i++)
        {
            lines.Add($"page {i}");
            lines.AddRange(RunAll(document, document.Pages[i]));
        }
        return lines;
    }

    private static IEnumerable<string> RunAll(PdfDocument document, PdfPage page)
    {
        var dump = new Dump();
        var interpreter = new ContentInterpreter(document);
        interpreter.Run(page, dump);
        dump.Flush();
        dump.Lines.Add($"truncated {B(interpreter.IsTruncated)}");
        return dump.Lines;
    }

    private static IEnumerable<string> Nest(int count)
    {
        string names = string.Join(' ', Enumerable.Range(0, count).Select(i => $"/F{i} {5 + i} 0 R"));
        var document = ContentTestPdf.Page("/F0 Do", $"/XObject <<{names}>>", pdf =>
        {
            for (int i = 0; i < count; i++) pdf.Stream(5 + i, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", $"0 0 1 1 re f /F{i + 1} Do");
        });
        var dump = new Dump();
        new ContentInterpreter(document).Run(document.Pages[0], dump);
        return [$"paths {dump.Paths} depth {dump.MaxDepth}"];
    }

    private static IEnumerable<string> Fonts(string rest)
    {
        string[] fields = rest.Split(" ;; ");
        var document = ContentTestPdf.Page("", "", pdf => AddObjects(pdf, fields[1..]));
        var font = PdfFont.Get(document, (PdfDictionary)document.Get(5)!);
        var lines = new List<string>
        {
            $"font subtype={font.Subtype} base={font.BaseFont} name={font.Name} composite={B(font.IsComposite)} type3={B(font.IsType3)} vertical={B(font.IsVertical)} " +
            $"embedded={B(font.IsEmbedded)} tounicode={B(font.HasToUnicode)} flags={font.Flags} bold={B(font.IsBold)} italic={B(font.IsItalic)} " +
            $"fixed={B(font.IsFixedPitch)} serif={B(font.IsSerif)} symbolic={B(font.IsSymbolic)} ascent={N(font.Ascent)} descent={N(font.Descent)} " +
            $"cap={N(font.CapHeight)} matrix={M(font.FontMatrix)} bbox={(font.FontBBox is { } box ? R(box) : "-")}",
        };
        byte[] bytes = Convert.FromHexString(fields[0].Replace(" ", ""));
        foreach (var c in font.Decode(bytes))
        {
            lines.Add($"char code={c.Code} len={c.Length} cid={c.Cid} w={N(c.Width)} u={U(c.Unicode)} space={B(c.IsSpace)} va={N(c.VerticalAdvance)} " +
                      $"ox={N(c.OriginX)} oy={N(c.OriginY)}");
        }
        lines.Add($"text {U(font.ToText(bytes))}");
        return lines;
    }

    private static string Color(PdfColor c)
    {
        var rgb = c.Rgb;
        return $"{c.Space.Family}({string.Join(",", c.Components.Select(N))}):{rgb.R},{rgb.G},{rgb.B}" + (c.PatternName is { } p ? ":" + p.Value : "");
    }

    private static string State(GraphicsState s) =>
        $"ctm={M(s.Ctm)} clip={R(s.Clip)} fill={Color(s.FillColor)} stroke={Color(s.StrokeColor)} lw={N(s.LineWidth)} cap={s.LineCap} join={s.LineJoin} " +
        $"miter={N(s.MiterLimit)} dash=[{string.Join(",", s.Dash.Select(N))}]@{N(s.DashPhase)} alpha={N(s.FillAlpha)}/{N(s.StrokeAlpha)} bm={s.BlendMode} " +
        $"sm={B(s.SoftMask is not null)} tc={N(s.CharSpacing)} tw={N(s.WordSpacing)} tz={N(s.HorizontalScale)} tl={N(s.Leading)} ts={N(s.Rise)} " +
        $"tr={s.RenderMode} font={s.Font?.Name ?? "-"} size={N(s.FontSize)}";

    private static string Segments(IReadOnlyList<PathSegment> segments) =>
        string.Join(";", segments.Select(s => s.Kind switch
        {
            PathSegmentKind.Move => $"M {N(s.X1)} {N(s.Y1)}",
            PathSegmentKind.Line => $"L {N(s.X1)} {N(s.Y1)}",
            PathSegmentKind.Curve => $"C {N(s.X1)} {N(s.Y1)} {N(s.X2)} {N(s.Y2)} {N(s.X3)} {N(s.Y3)}",
            _ => "Z",
        }));

    private sealed class Dump : ContentVisitor
    {
        private string? _event;
        private int _repeat;

        public List<string> Lines { get; } = [];
        public int Paths { get; private set; }
        public int MaxDepth { get; private set; }

        public void Flush()
        {
            if (_event is null) return;
            Lines.Add(_repeat > 1 ? $"{_event} x{_repeat}" : _event);
            _event = null;
        }

        private void Add(string line)
        {
            Flush();
            Lines.Add(line);
        }

        // Runs of the same event are one line: a thousand marked-content levels are not a thousand lines.
        private void Event(string line)
        {
            if (line == _event)
            {
                _repeat++;
                return;
            }
            Flush();
            (_event, _repeat) = (line, 1);
        }

        private static string Where(ContentContext c) => $"op={c.OperatorIndex} forms={c.Forms.Count} mcid={(c.Mcid is { } m ? m.ToString() : "-")}";

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            var c = glyph.Character;
            MaxDepth = Math.Max(MaxDepth, context.Forms.Count);
            Add($"glyph {Where(context)} code={c.Code} len={c.Length} cid={c.Cid} w={N(c.Width)} u={U(c.Unicode)} space={B(c.IsSpace)} va={N(c.VerticalAdvance)} " +
                $"ox={N(c.OriginX)} oy={N(c.OriginY)} m={M(glyph.Matrix)} box={R(glyph.Bounds)} adv={N(glyph.Advance)} el={glyph.Element} off={glyph.Offset} {State(context.State)}");
        }

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            Paths++;
            MaxDepth = Math.Max(MaxDepth, context.Forms.Count);
            Add($"path {Where(context)} {path.Operator} segs={Segments(path.Segments)} bounds={R(path.Bounds)} ink={R(path.InkBounds)} fill={B(path.Fill)} " +
                $"stroke={B(path.Stroke)} eo={B(path.EvenOdd)} clips={B(path.Clips)} {State(context.State)}");
        }

        public override void PaintImage(ContentContext context, ImageInfo image) =>
            Add($"image {Where(context)} name={image.Name ?? "-"} inline={B(image.Inline is not null)} stream={B(image.Stream is not null)} w={image.Width} h={image.Height} " +
                $"mask={B(image.IsMask)} oc={B(image.OptionalContent is not null)} m={M(image.Matrix)} bounds={R(image.Bounds)} dict={image.Dictionary}");

        public override void PaintShading(ContentContext context, ShadingInfo shading) =>
            Add($"shading {Where(context)} name={shading.Name} bounds={R(shading.Bounds)} kind={(shading.Shading is PdfStream ? "stream" : "dictionary")}");

        public override void BeginMarked(ContentContext context, MarkedContent marked) =>
            Event($"begin {Where(context)} tag={marked.Tag} mcid={(marked.Mcid is { } m ? m.ToString() : "-")} props={(marked.Properties is { } p ? p.ToString() : "-")} oc={B(marked.OptionalContent is not null)}");

        public override void EndMarked(ContentContext context, MarkedContent marked) =>
            Event($"end {Where(context)} tag={marked.Tag}");

        public override void BeginForm(ContentContext context, FormInfo form) =>
            Add($"{(form.IsPattern ? "pattern" : "form")} {Where(context)} name={form.Name ?? "-"} m={M(form.Matrix)} bounds={R(form.Bounds)} oc={B(form.OptionalContent is not null)}");

        public override void EndForm(ContentContext context, FormInfo form) => Add($"endform {Where(context)}");
    }
}
