using System.Text;

namespace LazyPDF.Core;

/// <summary>What a widget's /MK, border and /DA say about how it is drawn (ISO 32000-1 12.5.5, 12.7.3.3, 12.5.6.19).</summary>
internal sealed record Look(double RectWidth, double RectHeight, int Rotation, double[]? Background, double[]? BorderColor,
    double BorderWidth, BorderStyle Style, IReadOnlyList<double> Dash, string? Caption, double[] TextColor, double FontSize, string FontName, int Alignment)
{
    /// <summary>The size of the space the appearance is drawn in: the rectangle turned by /MK /R.</summary>
    public double Width => Rotation % 180 == 0 ? RectWidth : RectHeight;
    public double Height => Rotation % 180 == 0 ? RectHeight : RectWidth;

    /// <summary>Where the border ends and the content may start: bevels and insets take twice the width.</summary>
    public double Inset => BorderColor is null ? 0 : Style is BorderStyle.Beveled or BorderStyle.Inset ? 2 * BorderWidth : BorderWidth;

    public static Look Of(PdfDocument document, FormField field, FormWidget widget)
    {
        var d = widget.Dictionary;
        var mk = document.Dict(d, "MK");
        var border = PdfAnnotations.Parse(document, d, null)?.Border ?? new AnnotationBorder(1, BorderStyle.Solid, []);
        var (font, size, color) = DefaultAppearance.Parse(PdfText.Read(document, d, "DA") ?? field.DefaultAppearance);
        int rotation = (int)(((document.Integer(mk, "R") ?? 0) % 360 + 360) % 360 / 90 * 90);
        double[]? stroke = ColorOf(document, mk?["BC"]);
        return new Look(widget.Rect.Width, widget.Rect.Height, rotation, ColorOf(document, mk?["BG"]), stroke,
            stroke is null ? 0 : border.Width, border.Style, border.Dash, PdfText.Read(document, mk, "CA"),
            color ?? [0], size ?? 0, font ?? "Helv", (int)(document.Integer(d, "Q") ?? field.Alignment));
    }

    private static double[]? ColorOf(PdfDocument document, PdfObject? value)
    {
        var numbers = PdfAnnotations.Numbers(document, value);
        return numbers.Length is 1 or 3 or 4 ? numbers : null;
    }
}

/// <summary>
/// Draws the /AP /N streams of widgets from the field's value, /DA, /Q and the widget's /MK. The
/// system renderer ignores /NeedAppearances, so every value that changes goes through here.
/// </summary>
internal sealed partial class FormAppearance(PdfDocument document)
{
    private const double MinAutoSize = 4;
    private const double MaxAutoMultiline = 12;
    private const double MaxSize = 200;

    /// <summary>
    /// Replaces the widget's /AP. <paramref name="display"/> is the text shown (formatted, for text and
    /// choice fields) and <paramref name="font"/> the font it is set in; a check box or radio button needs
    /// no font; <paramref name="onState"/> names the "on" state of a button that has none yet. Signature fields are left as they are.
    /// </summary>
    public void Apply(FormField field, FormWidget widget, FormFont? font, string display, double[]? color = null, string? onState = null)
    {
        if (widget.Rect.IsEmpty || field.Kind == FieldKind.Signature) return;
        var look = Look.Of(document, field, widget);
        if (color is not null) look = look with { TextColor = color };
        switch (field.Kind)
        {
            case FieldKind.CheckBox or FieldKind.Radio:
                Buttons(field, widget, look, onState);
                return;
            case FieldKind.PushButton:
                if (document.Dict(widget.Dictionary, "MK") is { } mk && mk.ContainsKey("I")) return; // the icon is the artwork
                SetNormal(widget, PushButton(look, font!));
                return;
            case FieldKind.ListBox:
                SetNormal(widget, ListBox(field, look, font!));
                return;
            default:
                SetNormal(widget, TextField(field, look, font!, display));
                return;
        }
    }

    // The rollover and down states of a button survive a redraw of the normal one.
    private void SetNormal(FormWidget widget, PdfObject normal)
    {
        var ap = document.Dict(widget.Dictionary, "AP")?.Copy() ?? new PdfDictionary();
        ap["N"] = normal is PdfStream stream ? document.Add(stream) : normal;
        widget.Dictionary["AP"] = ap;
    }

    private static AppearanceCanvas NewCanvas(PdfDocument document, Look look) =>
        new(document, new PdfRect(0, 0, look.Width, look.Height));

    // The form's BBox is the unrotated drawing space; /Matrix turns it into the widget's rectangle.
    private static PdfStream Finish(AppearanceCanvas canvas, Look look)
    {
        var stream = canvas.ToStream();
        double w = look.RectWidth, h = look.RectHeight;
        double[] m = look.Rotation switch
        {
            90 => [0, 1, -1, 0, w, 0],
            180 => [-1, 0, 0, -1, w, h],
            270 => [0, -1, 1, 0, 0, h],
            _ => [1, 0, 0, 1, 0, 0],
        };
        stream.Dictionary["Matrix"] = new PdfArray([.. m.Select(n => (PdfObject)new PdfNumber(n))]);
        return stream;
    }

    private static void Frame(AppearanceCanvas c, Look look, bool ellipse)
    {
        double w = look.Width, h = look.Height, bw = look.BorderWidth;
        if (look.Background is not null && c.Color(look.Background, stroke: false))
        {
            if (ellipse) c.Ellipse(0, 0, w, h);
            else c.W.Rect(0, 0, w, h);
            c.W.Fill();
        }
        if (look.BorderColor is null || bw <= 0 || !c.Color(look.BorderColor, stroke: true)) return;
        if (look.Style == BorderStyle.Underline)
        {
            c.Stroke(bw, null);
            c.Move(0, bw / 2).Line(w, bw / 2);
            c.W.Stroke();
            return;
        }
        c.Stroke(bw, look.Style == BorderStyle.Dashed ? (look.Dash.Count > 0 ? look.Dash : [3]) : null);
        if (ellipse) c.Ellipse(bw / 2, bw / 2, w - bw / 2, h - bw / 2);
        else c.W.Rect(bw / 2, bw / 2, w - bw, h - bw);
        c.W.Stroke();
        if (ellipse || look.Style is not (BorderStyle.Beveled or BorderStyle.Inset)) return;

        bool raised = look.Style == BorderStyle.Beveled;
        c.Color(raised ? [1] : [0.5], stroke: false);
        c.Polyline([(bw, bw), (bw, h - bw), (w - bw, h - bw), (w - 2 * bw, h - 2 * bw), (2 * bw, h - 2 * bw), (2 * bw, 2 * bw)], close: true);
        c.W.Fill();
        c.Color(raised ? [0.5] : [0.75], stroke: false);
        c.Polyline([(w - bw, h - bw), (w - bw, bw), (bw, bw), (2 * bw, 2 * bw), (w - 2 * bw, 2 * bw), (w - 2 * bw, h - 2 * bw)], close: true);
        c.W.Fill();
    }

    // Text goes in marked content /Tx and a clip of the field's interior, as Acrobat writes it.
    private static void ShowLines(AppearanceCanvas c, Look look, FormFont font, double size, IEnumerable<(string Text, double X, double Y)> lines)
    {
        string name = c.AddFont(font.Reference);
        double inset = look.Inset;
        c.W.BeginMarked("Tx").Save();
        c.W.Rect(inset, inset, Math.Max(0, look.Width - 2 * inset), Math.Max(0, look.Height - 2 * inset)).Clip();
        c.Color(look.TextColor, stroke: false);
        c.W.BeginText().Font(name, size);
        foreach (var (text, x, y) in lines)
        {
            if (text.Length == 0) continue;
            c.W.TextMatrix(new PdfMatrix(1, 0, 0, 1, x, y));
            font.Show(c.W, text, size);
        }
        c.W.EndText().Restore().EndMarked();
    }

    internal static string Bullets(FormFont font, string text)
    {
        char mark = font.CanShow("•") ? '•' : '*';
        var sb = new StringBuilder();
        foreach (var rune in text.EnumerateRunes()) sb.Append(mark);
        return sb.ToString();
    }
}
