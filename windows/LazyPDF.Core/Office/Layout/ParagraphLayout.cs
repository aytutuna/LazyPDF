namespace LazyPDF.Core.Office;

internal sealed class Atom
{
    public int Code;
    public LayoutRun Run = null!;
    public FontFace RunFace = null!;
    public FontFace Face = null!;
    public double Size;
    public double Width;
    /// <summary>For a picture in line: the picture and its height after it was fitted to the line.</summary>
    public LayoutPicture? Picture;
    public double PictureHeight;
    /// <summary>From the left edge of the text area.</summary>
    public double X;
    /// <summary>Space added after the atom by justification.</summary>
    public double Extra;
    /// <summary>An explicit stop this tab runs to when the text is before it.</summary>
    public double? Stop;
    /// <summary>The bidi embedding level; odd is right to left. Set only for a paragraph that needs the algorithm.</summary>
    public int Level;
    /// <summary>Where the atom starts in the text the bidi algorithm ran on.</summary>
    public int Unit;

    public bool IsSpace => Code is ' ' or (>= 0x2000 and <= 0x200A and not 0x2007) or 0x1680 or 0x205F;
    public bool IsTab => Code == '\t';
    public bool IsNewline => Code == '\n';
    public bool IsZeroWidth => Code == 0x200B || Scripts.IsBidiControl(Code);
    public bool IsRightToLeft => (Level & 1) == 1;
    /// <summary>The left edge of the room the atom takes: justification adds its gap before a right-to-left atom.</summary>
    public double BoxLeft => IsRightToLeft ? X - Extra : X;
    public double BoxRight => IsRightToLeft ? X + Width : X + Width + Extra;
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
    public bool ComplexScript;

    public double Height => Lines.Sum(l => l.Height);
}

/// <summary>Breaks a paragraph into lines at a width: greedy, as Word fits them, with no kerning.</summary>
internal static class ParagraphLayout
{
    private const double Tolerance = 0.01;
    private const double TabWidth = 36;

    /// <summary>The code point a picture takes in the text; it breaks like an ideograph.</summary>
    public const int ObjectCode = 0xFFFC;

    /// <param name="maxHeight">The tallest a picture may be, so that one always fits a page.</param>
    public static ParagraphLines Run(LayoutParagraph paragraph, LayoutFonts fonts, double areaWidth, double maxHeight, Func<LayoutField, string>? field = null)
    {
        var result = new ParagraphLines { Source = paragraph };
        var atoms = Atoms(paragraph, fonts, field, result, out bool bidi);
        var order = bidi || paragraph.RightToLeft ? BidiText(atoms, paragraph) : null;
        var align = paragraph.RightToLeft ? Mirrored(paragraph.Align) : paragraph.Align;
        if (paragraph.LabelTab is { } labelTab && atoms.Find(a => a.IsTab) is { } labelAtom) labelAtom.Stop = labelTab;
        double left = Math.Max(0, paragraph.Left);
        double first = Math.Max(0, paragraph.Left + paragraph.FirstLine);
        double right = Math.Max(areaWidth - Math.Max(0, paragraph.Right), Math.Max(left, first) + 1);
        Fit(atoms, right - Math.Min(left, first), maxHeight, paragraph);

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
                Finish(result, line, right, justify: align == LayoutAlign.Justify, paragraph, align, order, areaWidth, fonts);
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
                    Finish(result, line, right, justify: align == LayoutAlign.Justify, paragraph, align, order, areaWidth, fonts);
                    line = new LayoutLine { Start = left };
                    x = left;
                }
                atom.X = x;
                x += Step(atom, x, left, right, place: true);
                line.Atoms.Add(atom);
            }
            if (atoms[end - 1].IsNewline)
            {
                Finish(result, line, right, justify: false, paragraph, align, order, areaWidth, fonts);
                line = new LayoutLine { Start = left };
                x = left;
            }
            i = end;
        }
        Finish(result, line, right, justify: false, paragraph, align, order, areaWidth, fonts);
        return result;
    }

    // A picture wider or taller than the room shrinks, keeping its shape.
    // The height leaves room for the descent, the multiple spacing and the space around the paragraph, so the line still fits.
    private static void Fit(List<Atom> atoms, double width, double height, LayoutParagraph paragraph)
    {
        double room = height - paragraph.Before - paragraph.After;
        if (paragraph.Rule == LineRule.Multiple && paragraph.LineSpacing > 1) room /= paragraph.LineSpacing;
        foreach (var atom in atoms)
        {
            if (atom.Picture is null) continue;
            double limit = room - atom.RunFace.Descent * atom.Size;
            double scale = Math.Min(1, Math.Min(Math.Max(1, width) / atom.Width, Math.Max(1, limit) / atom.PictureHeight));
            atom.Width *= scale;
            atom.PictureHeight *= scale;
        }
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

    private static List<Atom> Atoms(LayoutParagraph paragraph, LayoutFonts fonts, Func<LayoutField, string>? field, ParagraphLines result, out bool bidi)
    {
        bidi = false;
        var atoms = new List<Atom>();
        foreach (var run in paragraph.Runs)
        {
            var face = FaceOf(run, fonts);
            double size = Size(run);
            if (run.Picture is { } picture)
            {
                atoms.Add(new Atom { Code = ObjectCode, Run = run, RunFace = face, Face = face, Size = size, Width = picture.Width, Picture = picture, PictureHeight = picture.Height });
                continue;
            }
            string text = field is not null && run.Field != LayoutField.None ? field(run.Field) : run.Text;
            foreach (var rune in text.EnumerateRunes())
            {
                int code = rune.Value;
                if (code is 0xAD or 0x200C or 0x200D or 0x2060 or 0xFEFF or ObjectCode or (< 0x20 and not '\t' and not '\n') or (>= 0x7F and < 0xA0)) continue;
                bidi |= run.Rtl || Scripts.NeedsBidi(code);
                if (code is (>= 0x0900 and <= 0x0EFF) or (>= 0x0F00 and <= 0x109F) or (>= 0x1780 and <= 0x17FF)) result.ComplexScript = true;
                var atom = new Atom { Code = code, Run = run, RunFace = face, Face = face, Size = size };
                if (!atom.IsBlank || atom.IsSpace)
                {
                    atom.Face = fonts.Choose(face, code);
                    atom.Width = atom.Face.Advance(code) * size;
                }
                atoms.Add(atom);
            }
        }
        MeasureJoined(atoms, fonts.Shaper);
        return atoms;
    }

    private static bool IsArabic(Atom atom) =>
        atom.Picture is null && atom.Code is (>= 0x0600 and <= 0x06FF) or (>= 0x0750 and <= 0x077F) or (>= 0x08A0 and <= 0x08FF) or (>= 0xFB50 and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFF);

    // The writer draws an Arabic stretch with the joined glyphs of the shaper, whose advances differ from the isolated
    // letters'. Each glyph's advance goes to the atom its cluster starts in; the rest of a ligature gets none.
    private static void MeasureJoined(List<Atom> atoms, IShaper? shaper)
    {
        if (shaper is null) return;
        for (int i = 0; i < atoms.Count;)
        {
            if (!IsArabic(atoms[i])) { i++; continue; }
            int end = i + 1;
            while (end < atoms.Count && IsArabic(atoms[end]) && ReferenceEquals(atoms[end].Run, atoms[i].Run) && atoms[end].Face == atoms[i].Face) end++;
            var text = new System.Text.StringBuilder();
            var starts = new int[end - i];
            for (int k = i; k < end; k++)
            {
                starts[k - i] = text.Length;
                text.Append(char.ConvertFromUtf32(atoms[k].Code));
            }
            if (shaper.Shape(text.ToString(), atoms[i].Face.File, true, null) is { } glyphs)
            {
                for (int k = i; k < end; k++) atoms[k].Width = 0;
                foreach (var glyph in glyphs)
                {
                    int at = Array.BinarySearch(starts, Math.Clamp(glyph.Cluster, 0, text.Length - 1));
                    if (at < 0) at = ~at - 1;
                    atoms[i + at].Width += glyph.Advance / 1000 * atoms[i].Size;
                }
            }
            i = end;
        }
    }

    private static LayoutAlign Mirrored(LayoutAlign align) => align switch
    {
        LayoutAlign.Left => LayoutAlign.Right,
        LayoutAlign.Right => LayoutAlign.Left,
        _ => align,
    };

    // The text the bidi algorithm runs on: one character an atom (a tab and a line break are neutral), and a right-to-left run
    // inside a left-to-right paragraph embedded, so that the neutral characters in it go with its direction.
    private static BidiParagraph BidiText(List<Atom> atoms, LayoutParagraph paragraph)
    {
        var text = new System.Text.StringBuilder(atoms.Count + 2);
        bool embedded = false;
        foreach (var atom in atoms)
        {
            bool inside = atom.Run.Rtl && !paragraph.RightToLeft;
            if (inside != embedded)
            {
                text.Append(inside ? '\u202B' : '\u202C');
                embedded = inside;
            }
            atom.Unit = text.Length;
            text.Append(atom.IsNewline ? " " : char.ConvertFromUtf32(atom.Code));
        }
        if (embedded) text.Append('\u202C');
        return new BidiParagraph(text.ToString(), paragraph.RightToLeft ? 1 : 0);
    }

    private static FontFace FaceOf(LayoutRun run, LayoutFonts fonts)
    {
        var style = (run.Bold ? FontStyles.Bold : 0) | (run.Italic ? FontStyles.Italic : 0);
        return fonts.Find(run.Family, style) ?? fonts.Find(OfficeFontSource.DefaultFamily, style) ?? throw new InvalidOperationException(ExportText.NoFont);
    }

    internal static double Size(LayoutRun run) => run.Size > 0 ? Math.Min(run.Size, 1000) : 11;

    private static void Finish(ParagraphLines result, LayoutLine line, double right, bool justify, LayoutParagraph paragraph, LayoutAlign align, BidiParagraph? bidi, double areaWidth, LayoutFonts fonts)
    {
        Align(line, right, align, justify);
        if (bidi is not null) Reorder(line, bidi, paragraph.RightToLeft, areaWidth);
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

    // The atoms were placed in logical order from the start edge. Put them in display order (L2), left to right, from where the
    // line starts: the left of the text area, or for a right-to-left paragraph the right edge, which the area width gives.
    private static void Reorder(LayoutLine line, BidiParagraph bidi, bool rightToLeft, double areaWidth)
    {
        var atoms = line.Atoms;
        if (atoms.Count == 0) return;
        int first = atoms[0].Unit, end = atoms[^1].Unit + (atoms[^1].Code > 0xFFFF ? 2 : 1);
        var levels = bidi.LineLevels(first, end);
        foreach (var atom in atoms) atom.Level = levels[atom.Unit - first] is var l and >= 0 ? l : bidi.Level;

        var visual = Enumerable.Range(0, atoms.Count).ToList();
        int highest = atoms.Max(a => a.Level);
        int lowestOdd = atoms.Where(a => a.IsRightToLeft).Select(a => a.Level).DefaultIfEmpty(int.MaxValue).Min();
        for (int level = highest; level >= lowestOdd; level--)
        {
            for (int i = 0; i < visual.Count; i++)
            {
                if (atoms[visual[i]].Level < level) continue;
                int j = i;
                while (j + 1 < visual.Count && atoms[visual[j + 1]].Level >= level) j++;
                visual.Reverse(i, j - i + 1);
                i = j;
            }
        }

        double total = atoms.Sum(a => a.Width + a.Extra);
        double x = rightToLeft ? areaWidth - atoms[0].X - total : atoms[0].X;
        foreach (int k in visual)
        {
            var atom = atoms[k];
            atom.X = x + (atom.IsRightToLeft ? atom.Extra : 0);
            x += atom.Width + atom.Extra;
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
                ascent = Math.Max(ascent, (a.Picture is null ? a.RunFace.Ascent * a.Size : a.PictureHeight) + Math.Max(0, a.Run.Shift));
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
