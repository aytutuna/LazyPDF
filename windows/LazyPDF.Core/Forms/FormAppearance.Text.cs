namespace LazyPDF.Core;

internal sealed partial class FormAppearance
{
    private static readonly double[] Selection = [0.6, 0.75, 0.85];

    private PdfStream TextField(FormField field, Look look, FormFont font, string display)
    {
        var c = NewCanvas(document, look);
        Frame(c, look, ellipse: false);
        string text = field.Has(FieldFlags.Password) ? Bullets(font, display) : display;
        if (text.Length == 0) return Finish(c, look);

        double inset = look.Inset, pad = inset + 1;
        double availableWidth = Math.Max(1, look.Width - 2 * pad);
        double lineFit = (look.Height - 2 * inset - 2) / (font.Ascent - font.Descent);

        if (field.Has(FieldFlags.Comb) && field.MaxLength > 0 && !field.Has(FieldFlags.Multiline))
        {
            Comb(c, field, look, font, text);
        }
        else if (field.Has(FieldFlags.Multiline))
        {
            var (size, lines) = Multiline(font, text, look, availableWidth, pad);
            double y = look.Height - pad - font.Ascent * size;
            var placed = new List<(string, double, double)>();
            foreach (string line in lines)
            {
                placed.Add((line, AlignedX(look.Alignment, look.Width, pad, font.Width(line, size)), y));
                y -= font.LineHeight(size);
            }
            ShowLines(c, look, font, size, placed);
        }
        else
        {
            text = text.ReplaceLineEndings(" ");
            double size = look.FontSize > 0 ? look.FontSize : Math.Min(MaxSize, Math.Max(MinAutoSize, lineFit));
            double width = font.Width(text, size);
            if (look.FontSize <= 0 && width > availableWidth) size = Math.Max(MinAutoSize, size * availableWidth / width);
            width = font.Width(text, size);
            double baseline = (look.Height - font.LineHeight(size)) / 2 - font.Descent * size;
            ShowLines(c, look, font, size, [(text, AlignedX(look.Alignment, look.Width, pad, width), baseline)]);
        }
        return Finish(c, look);
    }

    private static double AlignedX(int alignment, double width, double pad, double textWidth) => alignment switch
    {
        1 => (width - textWidth) / 2,
        2 => width - pad - textWidth,
        _ => pad,
    };

    // 12.7.4.3: with the size 0 a multiline field starts at 12 points and shrinks until the text fits.
    private static (double Size, IReadOnlyList<string> Lines) Multiline(FormFont font, string text, Look look, double availableWidth, double pad)
    {
        double height = look.Height - 2 * pad;
        if (look.FontSize > 0) return (look.FontSize, font.Wrap(text, look.FontSize, availableWidth));
        for (double size = MaxAutoMultiline; ; size -= 0.5)
        {
            var lines = font.Wrap(text, size, availableWidth);
            if (size <= MinAutoSize || lines.Count * font.LineHeight(size) <= height) return (size, lines);
        }
    }

    private static void Comb(AppearanceCanvas c, FormField field, Look look, FormFont font, string text)
    {
        var chars = text.EnumerateRunes().Take(field.MaxLength).Select(r => r.ToString()).ToList();
        double inset = look.Inset;
        double cell = (look.Width - 2 * inset) / field.MaxLength;
        double size = look.FontSize;
        if (size <= 0)
        {
            size = Math.Min(MaxSize, Math.Max(MinAutoSize, (look.Height - 2 * inset - 2) / (font.Ascent - font.Descent)));
            double widest = chars.Max(ch => font.Width(ch, 1));
            if (widest * size > cell - 1) size = Math.Max(MinAutoSize, (cell - 1) / widest);
        }
        if (look.BorderColor is not null && look.BorderWidth > 0 && c.Color(look.BorderColor, stroke: true))
        {
            c.Stroke(look.BorderWidth, null);
            for (int i = 1; i < field.MaxLength; i++)
            {
                c.Move(inset + cell * i, 0).Line(inset + cell * i, look.Height);
            }
            c.W.Stroke();
        }
        double baseline = (look.Height - font.LineHeight(size)) / 2 - font.Descent * size;
        // A short text sits at the start, in the middle or at the end of the cells as /Q says.
        double offset = (field.MaxLength - chars.Count) * cell * look.Alignment / 2.0;
        var placed = new List<(string, double, double)>();
        for (int i = 0; i < chars.Count; i++)
        {
            placed.Add((chars[i], inset + offset + cell * i + (cell - font.Width(chars[i], size)) / 2, baseline));
        }
        ShowLines(c, look, font, size, placed);
    }

    private PdfStream ListBox(FormField field, Look look, FormFont font)
    {
        var c = NewCanvas(document, look);
        Frame(c, look, ellipse: false);
        double inset = look.Inset, pad = inset + 1;
        double size = look.FontSize > 0 ? look.FontSize : MaxAutoMultiline;
        double row = font.LineHeight(size);
        int visible = Math.Max(1, (int)((look.Height - 2 * pad) / row));
        var selected = SelectedIndexes(field);
        int top = (int)Math.Clamp(document.Integer(field.Dictionary, "TI") ?? 0, 0, Math.Max(0, field.Options.Count - 1));
        if (selected.Count > 0)
        {
            if (selected[0] < top) top = selected[0];
            else if (selected[0] >= top + visible) top = selected[0] - visible + 1;
        }
        top = Math.Clamp(top, 0, Math.Max(0, field.Options.Count - visible));
        if (top > 0) field.Dictionary["TI"] = new PdfNumber(top);
        else field.Dictionary.Remove("TI");

        var lines = new List<(string, double, double)>();
        for (int i = top; i < field.Options.Count && i < top + visible + 1; i++)
        {
            double rowTop = look.Height - pad - (i - top) * row;
            if (selected.Contains(i) && c.Color(Selection, stroke: false))
            {
                c.W.Rect(inset, rowTop - row, look.Width - 2 * inset, row).Fill();
            }
            lines.Add((field.Options[i].Display, AlignedX(look.Alignment, look.Width, pad, font.Width(field.Options[i].Display, size)), rowTop - font.Ascent * size));
        }
        ShowLines(c, look, font, size, lines);
        return Finish(c, look);
    }

    // /I names the selected items by index; without it the values in /V are looked up in /Opt.
    internal List<int> SelectedIndexes(FormField field)
    {
        var chosen = new List<int>();
        if (document.Array(field.Dictionary, "I") is { } indexes)
        {
            foreach (var item in indexes.Items)
            {
                if (document.Resolve(item) is PdfNumber { Integer: { } i } && i >= 0 && i < field.Options.Count) chosen.Add((int)i);
            }
        }
        else
        {
            for (int i = 0; i < field.Options.Count; i++)
            {
                if (field.Selected.Contains(field.Options[i].Export)) chosen.Add(i);
            }
        }
        chosen.Sort();
        return chosen;
    }
}
