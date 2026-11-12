namespace LazyPDF.Core.Office;

internal sealed class Atom
{
    public int Code;
    public LayoutRun Run = null!;
    public FontFace RunFace = null!;
    public FontFace Face = null!;
    public double Size;
    public double Width;
    /// <summary>From the left edge of the text area.</summary>
    public double X;
    /// <summary>Space added after the atom by justification.</summary>
    public double Extra;
    /// <summary>An explicit stop this tab runs to when the text is before it.</summary>
    public double? Stop;

    public bool IsSpace => Code is ' ' or (>= 0x2000 and <= 0x200A and not 0x2007) or 0x1680 or 0x205F;
    public bool IsTab => Code == '\t';
    public bool IsNewline => Code == '\n';
    public bool IsZeroWidth => Code == 0x200B;
    /// <summary>Takes room (or none) but draws nothing.</summary>
    public bool IsBlank => IsSpace || IsTab || IsNewline || IsZeroWidth;
}

internal sealed class LayoutLine
{
    public List<Atom> Atoms { get; } = [];
    public double Height;
    /// <summary>From the top of the line.</summary>
    public double Baseline;
    public double Start;
}

internal sealed class ParagraphLines
{
    public required LayoutParagraph Source { get; init; }
    public List<LayoutLine> Lines { get; } = [];
    public bool RightToLeft;
    public bool ComplexScript;

    public double Height => Lines.Sum(l => l.Height);
}

/// <summary>Breaks a paragraph into lines at a width: greedy, as Word fits them, with no kerning.</summary>
internal static class ParagraphLayout
{
    private const double Tolerance = 0.01;
    private const double TabWidth = 36;

    public static ParagraphLines Run(LayoutParagraph paragraph, LayoutFonts fonts, double areaWidth, Func<LayoutField, string>? field = null)
    {
        var result = new ParagraphLines { Source = paragraph };
        var atoms = Atoms(paragraph, fonts, field, result);
        if (paragraph.LabelTab is { } labelTab && atoms.Find(a => a.IsTab) is { } labelAtom) labelAtom.Stop = labelTab;
        double left = Math.Max(0, paragraph.Left);
        double first = Math.Max(0, paragraph.Left + paragraph.FirstLine);
        double right = Math.Max(areaWidth - Math.Max(0, paragraph.Right), Math.Max(left, first) + 1);

        var breaks = LineBreaker.Opportunities(atoms.Select(a => a.Code).ToList());
        var line = new LayoutLine { Start = first };
        double x = first;
        int i = 0;
        while (i < atoms.Count)
        {
            int end = i + 1;
            while (end < atoms.Count && !breaks[end]) end++;
            int visible = end;
            while (visible > i && atoms[visible - 1].IsBlank && !atoms[visible - 1].IsTab) visible--;

            double reach = x;
            for (int k = i; k < visible; k++) reach += Step(atoms[k], reach, left, right, place: false);
            bool tooWide = reach > right + Tolerance;
            if (tooWide && line.Atoms.Count > 0)
            {
                Finish(result, line, right, justify: paragraph.Align == LayoutAlign.Justify, paragraph, fonts);
                line = new LayoutLine { Start = left };
                x = left;
                continue;
            }
            for (int k = i; k < end; k++)
            {
                var atom = atoms[k];
                // A segment wider than the line is cut where it runs out.
                if (tooWide && k < visible && line.Atoms.Count > 0 && x + Step(atom, x, left, right, place: false) > right + Tolerance)
                {
                    Finish(result, line, right, justify: paragraph.Align == LayoutAlign.Justify, paragraph, fonts);
                    line = new LayoutLine { Start = left };
                    x = left;
                }
                atom.X = x;
                x += Step(atom, x, left, right, place: true);
                line.Atoms.Add(atom);
            }
            if (atoms[end - 1].IsNewline)
            {
                Finish(result, line, right, justify: false, paragraph, fonts);
                line = new LayoutLine { Start = left };
                x = left;
            }
            i = end;
        }
        Finish(result, line, right, justify: false, paragraph, fonts);
        return result;
    }

    // The width an atom takes at x. A tab runs to the hanging indent or the next default stop, never past the right edge.
    private static double Step(Atom atom, double x, double left, double right, bool place)
    {
        if (!atom.IsTab) return atom.Width;
        double stop = x < left - Tolerance ? left : (Math.Floor(x / TabWidth) + 1) * TabWidth;
        if (atom.Stop is { } explicitStop && x < explicitStop - Tolerance) stop = x < left - Tolerance ? Math.Min(left, explicitStop) : explicitStop;
        double width = Math.Max(0, Math.Min(stop, Math.Max(right, x)) - x);
        if (place) atom.Width = width;
        return width;
    }

    private static List<Atom> Atoms(LayoutParagraph paragraph, LayoutFonts fonts, Func<LayoutField, string>? field, ParagraphLines result)
    {
        var atoms = new List<Atom>();
        foreach (var run in paragraph.Runs)
        {
            var face = FaceOf(run, fonts);
            double size = Size(run);
            string text = field is not null && run.Field != LayoutField.None ? field(run.Field) : run.Text;
            foreach (var rune in text.EnumerateRunes())
            {
                int code = rune.Value;
                if (code is 0xAD or 0x200C or 0x200D or 0x2060 or 0xFEFF or (< 0x20 and not '\t' and not '\n') or (>= 0x7F and < 0xA0)) continue;
                if (code is (>= 0x0590 and <= 0x08FF) or (>= 0xFB1D and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFF) or (>= 0x10800 and <= 0x10FFF) or (>= 0x1E800 and <= 0x1EFFF)) result.RightToLeft = true;
                else if (code is (>= 0x0900 and <= 0x0EFF) or (>= 0x0F00 and <= 0x109F) or (>= 0x1780 and <= 0x17FF)) result.ComplexScript = true;
                var atom = new Atom { Code = code, Run = run, RunFace = face, Face = face, Size = size };
                if (!atom.IsBlank || atom.IsSpace)
                {
                    atom.Face = fonts.Choose(face, code);
                    atom.Width = atom.Face.Advance(code) * size;
                }
                atoms.Add(atom);
            }
        }
        return atoms;
    }

    private static FontFace FaceOf(LayoutRun run, LayoutFonts fonts)
    {
        var style = (run.Bold ? FontStyles.Bold : 0) | (run.Italic ? FontStyles.Italic : 0);
        return fonts.Find(run.Family, style) ?? fonts.Find(OfficeFontSource.DefaultFamily, style) ?? throw new InvalidOperationException(ExportText.NoFont);
    }

    internal static double Size(LayoutRun run) => run.Size > 0 ? Math.Min(run.Size, 1000) : 11;

    private static void Finish(ParagraphLines result, LayoutLine line, double right, bool justify, LayoutParagraph paragraph, LayoutFonts fonts)
    {
        Align(line, right, paragraph.Align, justify);
        Measure(line, paragraph, fonts);
        result.Lines.Add(line);
    }

    private static void Align(LayoutLine line, double right, LayoutAlign align, bool justify)
    {
        int ink = line.Atoms.FindLastIndex(a => !a.IsBlank || a.IsTab);
        if (ink < 0) return;
        double room = Math.Max(0, right - line.Start - (line.Atoms[ink].X + line.Atoms[ink].Width - line.Start));
        if (align == LayoutAlign.Center || align == LayoutAlign.Right)
        {
            double shift = align == LayoutAlign.Center ? room / 2 : room;
            foreach (var a in line.Atoms) a.X += shift;
        }
        else if (justify && room > 0 && !line.Atoms.Any(a => a.IsTab))
        {
            int gaps = line.Atoms.Take(ink).Count(a => a.Code == ' ');
            if (gaps == 0) return;
            double extra = room / gaps, shift = 0;
            for (int k = 0; k < line.Atoms.Count; k++)
            {
                var a = line.Atoms[k];
                a.X += shift;
                if (k < ink && a.Code == ' ')
                {
                    a.Extra = extra;
                    shift += extra;
                }
            }
        }
    }

    // A single-spaced line is the tallest ascent plus the deepest descent, the line gap included; the extra
    // of a larger spacing goes above the text, as in Word.
    private static void Measure(LayoutLine line, LayoutParagraph paragraph, LayoutFonts fonts)
    {
        double ascent = 0, descent = 0;
        if (line.Atoms.Count > 0)
        {
            foreach (var a in line.Atoms)
            {
                ascent = Math.Max(ascent, a.RunFace.Ascent * a.Size + Math.Max(0, a.Run.Shift));
                descent = Math.Max(descent, a.RunFace.Descent * a.Size + Math.Max(0, -a.Run.Shift));
            }
        }
        else
        {
            var run = paragraph.Runs.Count > 0 ? paragraph.Runs[0] : new LayoutRun();
            var face = FaceOf(run, fonts);
            ascent = face.Ascent * Size(run);
            descent = face.Descent * Size(run);
        }
        double natural = ascent + descent;
        double spacing = paragraph.LineSpacing > 0 ? paragraph.LineSpacing : 1;
        line.Height = paragraph.Rule switch
        {
            LineRule.Exact => spacing,
            LineRule.AtLeast => Math.Max(natural, spacing),
            _ => natural * spacing,
        };
        line.Baseline = line.Height - descent;
    }
}
