using System.Text;

namespace LazyPDF.Core;

/// <summary>A glyph on its way from the interpreter to the layout: user space data from the content, display space data for the layout.</summary>
internal sealed class FlowGlyph
{
    public string Text = "";
    public TextQuad Quad;
    public PdfFont? Font;
    public double Size;
    public RgbColor Color;
    public int Mode;
    public int Op = -1;
    public PdfStream? Form;
    public int Element, Offset;
    public int? Mcid;
    public bool Artifact, Vertical, Space, Implied;

    /// <summary>Where the baseline sits in the box, from its bottom edge, as a fraction of its height.</summary>
    public double Base = 0.2;

    public TextQuad Display;
    public double Em, Angle;
    public double X0, X1, Y, Ya, Yb;
    public int Level;
    public int Run;
}

/// <summary>Gathers the glyphs a page shows, with the clip, invisibility, /ActualText and artifact rules applied.</summary>
internal sealed class TextCollector(TextPageOptions options) : ContentVisitor
{
    private const int MaxGlyphs = 1_000_000;
    private const int MaxCellScan = 64;

    private readonly List<(MarkedContent Marked, int Start, string Text)> _spans = [];

    public List<FlowGlyph> Glyphs { get; } = [];

    /// <summary>The page had more glyphs than are kept.</summary>
    public bool IsFull { get; private set; }

    public override void ShowGlyph(ContentContext context, in GlyphInfo info)
    {
        var state = context.State;
        if (state.RenderMode == 7) return;
        if (Glyphs.Count >= MaxGlyphs)
        {
            IsFull = true;
            return;
        }
        var m = info.Matrix;
        double size = Math.Sqrt(m.C * m.C + m.D * m.D);
        var font = info.Font;
        double ascent, descent;
        if (font.IsType3)
        {
            // The glyphs of a Type 3 font have the size its /FontMatrix and /FontBBox give, not the font size.
            ascent = font.Ascent > 0 ? font.Ascent / 1000 : 0.8;
            descent = font.Descent < 0 ? font.Descent / 1000 : -0.2;
            size *= Math.Max(ascent - descent, 1e-3);
        }
        else
        {
            ascent = font.Ascent > 0 ? Math.Min(font.Ascent / 1000, 1.1) : 0.8;
            descent = font.Descent < 0 ? Math.Max(font.Descent / 1000, -0.4) : -0.2;
        }
        if (!(size > 1e-6) || !double.IsFinite(size) || !double.IsFinite(m.E) || !double.IsFinite(m.F)) return;

        ascent = Math.Max(ascent, font.IsType3 ? 1e-3 : 0.5);
        double width = Math.Max(info.Character.Width / 1000, 0);
        var (x0, y0) = m.Transform(0, descent);
        var (x1, y1) = m.Transform(width, descent);
        var (x2, y2) = m.Transform(width, ascent);
        var (x3, y3) = m.Transform(0, ascent);
        var quad = new TextQuad(x0, y0, x1, y1, x2, y2, x3, y3);
        if (!double.IsFinite(quad.X0 + quad.Y0 + quad.X1 + quad.Y1 + quad.X2 + quad.Y2 + quad.X3 + quad.Y3)) return;

        var box = quad.Bounds;
        var clip = state.Clip;
        if (box.Right < clip.Left || box.Left > clip.Right || box.Top < clip.Bottom || box.Bottom > clip.Top) return;

        bool artifact = false;
        int? mcid = null;
        if (context.Marked.Count > 0)
        {
            artifact = context.Marked.Any(x => x.Tag == "Artifact");
            mcid = context.Mcid;
        }
        if (artifact && !options.IncludeArtifacts) return;

        string text = info.Unicode ?? (info.Character.IsSpace ? " " : "");
        text = TextNormal.Clean(text);
        Glyphs.Add(new FlowGlyph
        {
            Text = text,
            Quad = quad,
            Font = font,
            Size = size,
            Color = (state.RenderMode == 1 ? state.StrokeColor : state.FillColor).Rgb,
            Mode = state.RenderMode,
            Op = context.OperatorIndex,
            Form = context.Forms.Count > 0 ? context.Forms[^1] : null,
            Element = info.Element,
            Offset = info.Offset,
            Mcid = mcid,
            Artifact = artifact,
            Vertical = font.IsVertical,
            Space = IsBlank(text),
            Base = -descent / (ascent - descent),
        });
    }

    public override void BeginMarked(ContentContext context, MarkedContent marked)
    {
        if (_spans.Count > 0 || marked.Properties is null) return;
        if (context.Document.Resolve(marked.Properties["ActualText"]) is PdfString s)
        {
            _spans.Add((marked, Glyphs.Count, TextNormal.Clean(PdfText.Decode(s.Bytes))));
        }
    }

    public override void EndMarked(ContentContext context, MarkedContent marked)
    {
        if (_spans.Count == 0 || !ReferenceEquals(_spans[0].Marked, marked)) return;
        var (_, start, text) = _spans[0];
        _spans.Clear();
        Replace(start, text);
    }

    public static bool IsBlank(string text) => text.Length > 0 && text.All(char.IsWhiteSpace);

    // ISO 32000-1 14.9.4: the text replaces the glyphs. One piece per line the glyphs run over, the
    // text on the first, so that a hit on it still covers everything it stands for.
    private void Replace(int start, string text)
    {
        int count = Glyphs.Count - start;
        if (count <= 0) return;
        var glyphs = Glyphs.GetRange(start, count);
        Glyphs.RemoveRange(start, count);
        if (text.Length == 0) return;
        var group = new List<FlowGlyph> { glyphs[0] };
        bool first = true;
        for (int i = 1; i <= glyphs.Count; i++)
        {
            if (i < glyphs.Count && SameLine(group[^1], glyphs[i]))
            {
                group.Add(glyphs[i]);
                continue;
            }
            Glyphs.Add(Merge(group, first ? text : ""));
            first = false;
            group = i < glyphs.Count ? [glyphs[i]] : [];
        }
    }

    private static bool SameLine(FlowGlyph a, FlowGlyph b)
    {
        var (ca, cb) = (a.Quad.Center, b.Quad.Center);
        double rx = a.Vertical ? a.Quad.X0 - a.Quad.X3 : a.Quad.X1 - a.Quad.X0;
        double ry = a.Vertical ? a.Quad.Y0 - a.Quad.Y3 : a.Quad.Y1 - a.Quad.Y0;
        double length = Math.Sqrt(rx * rx + ry * ry);
        if (length < 1e-9) return true;
        double across = Math.Abs((cb.X - ca.X) * ry - (cb.Y - ca.Y) * rx) / length;
        return across < 0.5 * a.Size;
    }

    private static FlowGlyph Merge(List<FlowGlyph> group, string text)
    {
        var box = new QuadBox();
        foreach (var g in group) box.Add(g.Quad);
        var f = group[0];
        return new FlowGlyph
        {
            Text = text,
            Quad = box.ToQuad(),
            Font = f.Font,
            Size = f.Size,
            Color = f.Color,
            Mode = f.Mode,
            Op = f.Op,
            Form = f.Form,
            Element = f.Element,
            Offset = f.Offset,
            Mcid = f.Mcid,
            Artifact = f.Artifact,
            Vertical = f.Vertical,
            Space = IsBlank(text),
            Base = f.Base,
        };
    }

    /// <summary>Drops a glyph drawn again at nearly the same place (fake bold, drop shadows).</summary>
    public void RemoveDuplicates()
    {
        const double cell = 4;
        var grid = new Dictionary<(long, long), List<FlowGlyph>>();
        var kept = new List<FlowGlyph>(Glyphs.Count);
        foreach (var g in Glyphs)
        {
            if (g.Text.Length == 0 || g.Space)
            {
                kept.Add(g);
                continue;
            }
            long cx = (long)Math.Floor(g.Quad.X0 / cell), cy = (long)Math.Floor(g.Quad.Y0 / cell);
            // Adjacent narrow letters of the same kind (ll) sit closer than 0.2 em, so the reach is
            // also held under a quarter of the glyph's own advance.
            double advance = Math.Sqrt((g.Quad.X1 - g.Quad.X0) * (g.Quad.X1 - g.Quad.X0) + (g.Quad.Y1 - g.Quad.Y0) * (g.Quad.Y1 - g.Quad.Y0));
            double reach = advance > 1e-9 ? Math.Min(0.2 * g.Size, 0.25 * advance) : 0.2 * g.Size;
            bool duplicate = false;
            for (long i = cx - 1; i <= cx + 1 && !duplicate; i++)
            {
                for (long j = cy - 1; j <= cy + 1 && !duplicate; j++)
                {
                    if (!grid.TryGetValue((i, j), out var list)) continue;
                    for (int k = list.Count - 1; k >= Math.Max(0, list.Count - MaxCellScan); k--)
                    {
                        var o = list[k];
                        if (o.Text == g.Text && Math.Abs(o.Size - g.Size) < 0.1 * g.Size
                            && Math.Abs(o.Quad.X0 - g.Quad.X0) < reach && Math.Abs(o.Quad.Y0 - g.Quad.Y0) < reach)
                        {
                            duplicate = true;
                            break;
                        }
                    }
                }
            }
            if (duplicate) continue;
            kept.Add(g);
            if (!grid.TryGetValue((cx, cy), out var own)) grid[(cx, cy)] = own = [];
            own.Add(g);
        }
        Glyphs.Clear();
        Glyphs.AddRange(kept);
    }
}

internal static class TextNormal
{
    /// <summary>Removes control characters and folds ligature and presentation form code points to the letters they stand for.</summary>
    public static string Clean(string text)
    {
        bool fold = false, drop = false;
        foreach (char c in text)
        {
            if (c < 0x20 || (c >= 0x7F && c < 0xA0) || c is '\u200B' or '\uFEFF') drop = true;
            else if ((c >= '\uFB00' && c <= '\uFDFF') || (c >= '\uFE70' && c <= '\uFEFF')) fold = true;
        }
        if (!drop && !fold) return text;
        if (drop)
        {
            var sb = new StringBuilder(text.Length);
            foreach (char c in text)
            {
                if (c < 0x20 || (c >= 0x7F && c < 0xA0) || c is '\u200B' or '\uFEFF') continue;
                sb.Append(c);
            }
            text = sb.ToString();
        }
        if (!fold) return text;
        try
        {
            return text.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            return text; // a lone surrogate from a bad ToUnicode map
        }
    }
}
