namespace LazyPDF.Core;

internal sealed partial class FormAppearance
{
    // The marks of /MK /CA for check boxes and radio buttons are ZapfDingbats characters; the six
    // Acrobat offers are drawn as paths so that no font is needed.
    private const char Check = '4', Circle = 'l', Cross = '8', Diamond = 'u', Square = 'n', Star = 'H';

    private void Buttons(FormField field, FormWidget widget, Look look, string? onState)
    {
        string on = widget.OnState ?? onState ?? "Yes";
        char mark = look.Caption is { Length: > 0 } caption ? caption[0] : field.Kind == FieldKind.Radio ? Circle : Check;
        bool round = field.Kind == FieldKind.Radio && mark == Circle;
        var states = new PdfDictionary
        {
            [on] = document.Add(ButtonState(look, mark, round, isOn: true)),
            ["Off"] = document.Add(ButtonState(look, mark, round, isOn: false)),
        };
        SetNormal(widget, states);
    }

    private PdfStream ButtonState(Look look, char mark, bool round, bool isOn)
    {
        var c = NewCanvas(document, look);
        Frame(c, look, round);
        if (isOn) DrawMark(c, look, mark);
        return Finish(c, look);
    }

    private void DrawMark(AppearanceCanvas c, Look look, char mark)
    {
        double available = Math.Max(1, Math.Min(look.Width, look.Height) - 2 * (look.Inset + 1));
        double s = look.FontSize > 0 ? Math.Min(look.FontSize, available) : available;
        double cx = look.Width / 2, cy = look.Height / 2;
        c.W.BeginMarked("Tx").Save();
        c.Color(look.TextColor, stroke: false);
        c.Color(look.TextColor, stroke: true);
        switch (mark)
        {
            case Check:
                c.W.Op("J", 1).Op("j", 1).LineWidth(0.14 * s);
                c.Move(cx - 0.30 * s, cy - 0.02 * s).Line(cx - 0.08 * s, cy - 0.26 * s).Line(cx + 0.32 * s, cy + 0.30 * s);
                c.W.Stroke();
                break;
            case Cross:
                c.W.Op("J", 1).LineWidth(0.14 * s);
                c.Move(cx - 0.28 * s, cy - 0.28 * s).Line(cx + 0.28 * s, cy + 0.28 * s);
                c.Move(cx - 0.28 * s, cy + 0.28 * s).Line(cx + 0.28 * s, cy - 0.28 * s);
                c.W.Stroke();
                break;
            case Circle:
                c.Ellipse(cx - 0.3 * s, cy - 0.3 * s, cx + 0.3 * s, cy + 0.3 * s);
                c.W.Fill();
                break;
            case Diamond:
                c.Polyline([(cx, cy + 0.38 * s), (cx + 0.38 * s, cy), (cx, cy - 0.38 * s), (cx - 0.38 * s, cy)], close: true);
                c.W.Fill();
                break;
            case Square:
                c.W.Rect(cx - 0.28 * s, cy - 0.28 * s, 0.56 * s, 0.56 * s).Fill();
                break;
            case Star:
                var points = new List<(double, double)>();
                for (int i = 0; i < 10; i++)
                {
                    double r = (i % 2 == 0 ? 0.44 : 0.18) * s, angle = Math.PI / 2 + i * Math.PI / 5;
                    points.Add((cx + r * Math.Cos(angle), cy + r * Math.Sin(angle) - 0.02 * s));
                }
                c.Polyline(points, close: true);
                c.W.Fill();
                break;
            default:
                Dingbat(c, mark, s, cx, cy);
                break;
        }
        c.W.Restore().EndMarked();
    }

    private void Dingbat(AppearanceCanvas c, char mark, double size, double cx, double cy)
    {
        var zapf = Standard14.Find("ZapfDingbats")!;
        var font = document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Font"),
            ["Subtype"] = new PdfName("Type1"),
            ["BaseFont"] = new PdfName(zapf.Name),
        });
        double width = (zapf.BuiltInEncoding[mark & 0xFF] is { } glyph ? zapf.WidthOf(glyph) : null) ?? 800;
        c.W.BeginText().Font(c.AddFont(font), size).TextMatrix(new PdfMatrix(1, 0, 0, 1, cx - width * size / 2000, cy - 0.35 * size)).Show([(byte)mark]).EndText();
    }

    private PdfStream PushButton(Look look, FormFont font)
    {
        var c = NewCanvas(document, look);
        Frame(c, look, ellipse: false);
        if (look.Caption is not { Length: > 0 } caption) return Finish(c, look);

        double pad = look.Inset + 1;
        double size = look.FontSize;
        if (size <= 0)
        {
            size = Math.Min(MaxSize, Math.Max(MinAutoSize, (look.Height - 2 * look.Inset - 2) / (font.Ascent - font.Descent)));
            double width = font.Width(caption, size);
            if (width > look.Width - 2 * pad) size = Math.Max(MinAutoSize, size * (look.Width - 2 * pad) / width);
        }
        double baseline = (look.Height - font.LineHeight(size)) / 2 - font.Descent * size;
        ShowLines(c, look, font, size, [(caption, (look.Width - font.Width(caption, size)) / 2, baseline)]);
        return Finish(c, look);
    }
}
