using System.Text;

namespace LazyPDF.Core;

/// <summary>How a new text box looks.</summary>
/// <param name="Family">Asked of the editor's <see cref="IFontSource"/>; Arial, Times New Roman and Courier New use the Standard 14 fonts when the text fits.</param>
/// <param name="Size">Font size in points as the page is shown.</param>
/// <param name="LineSpacing">Multiplies the font's line height.</param>
public sealed record TextBoxStyle(string Family = "Helvetica", FontStyles Style = FontStyles.Regular, double Size = 12, RgbColor Color = default,
    TextAlignment Alignment = TextAlignment.Left, double LineSpacing = 1);

/// <summary>How a new line, rectangle or ellipse is painted; a null colour is not painted.</summary>
public sealed record ShapeStyle(RgbColor? Stroke = null, RgbColor? Fill = null, double Width = 1, double Opacity = 1);

public sealed partial class PageEditor
{
    /// <summary>
    /// Adds text wrapped inside <paramref name="box"/> (user space), upright on the page as it is
    /// shown. The top of the box is the top of the first line. When the lines are taller than the
    /// box the result says <see cref="TextEditResult.Overlaps"/>.
    /// </summary>
    public TextEditResult AddTextBox(PdfRect box, string text, TextBoxStyle? style = null)
    {
        style ??= new TextBoxStyle();
        if (box.IsEmpty || text.Length == 0) return TextEditResult.Failed(EditingText.TooBig);
        var model = Model;
        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        var embedder = new PdfFontEmbedder(model.Document, _fonts);
        var draw = embedder.Add(style.Family, style.Style, [text]);
        if (draw is null) return TextEditResult.Failed(EditingText.NoFont);
        if (draw.Missing.Count > 0)
        {
            batch.Discard();
            return TextEditResult.Failed(string.Format(EditingText.NoGlyphs, string.Concat(draw.Missing.Select(char.ConvertFromUtf32))));
        }

        var geometry = new PageGeometry(model.Page);
        var shown = geometry.ToDisplay(box);
        var origin = geometry.ToUser(0, 0);
        var across = geometry.ToUser(1, 0);
        var up = geometry.ToUser(0, -1);
        var (ax, ay) = (across.X - origin.X, across.Y - origin.Y);
        var (bx, by) = (up.X - origin.X, up.Y - origin.Y);
        var lines = draw.Wrap(text, style.Size, shown.Width);
        double height = draw.LineHeight(style.Size) * style.LineSpacing;
        string name = batch.NewName();
        var w = new ContentWriter().Save();
        w.FillRgb(style.Color.R / 255.0, style.Color.G / 255.0, style.Color.B / 255.0);
        w.BeginText().Font(name, style.Size);
        for (int i = 0; i < lines.Count; i++)
        {
            double width = draw.Width(lines[i], style.Size);
            double x = style.Alignment switch
            {
                TextAlignment.Center => shown.X + (shown.Width - width) / 2,
                TextAlignment.Right => shown.X + shown.Width - width,
                _ => shown.X,
            };
            double y = shown.Y + draw.Ascent * style.Size + i * height;
            var (ux, uy) = geometry.ToUser(x, y);
            bool justify = style.Alignment == TextAlignment.Justify && !draw.IsEmbedded && i < lines.Count - 1 && lines[i].Contains(' ');
            if (justify) w.WordSpacing((shown.Width - width) / lines[i].Count(c => c == ' ') / Math.Sqrt(ax * ax + ay * ay));
            w.TextMatrix(new PdfMatrix(ax, ay, bx, by, ux, uy));
            w.Show(draw.Encode(lines[i]));
            if (justify) w.WordSpacing(0);
        }
        w.EndText().Restore();
        batch.Append(w.ToArray(), ("Font", name, draw.Reference));
        double bottom = shown.Y + draw.Ascent * style.Size + (lines.Count - 1) * height - draw.Descent * style.Size;
        var result = Finish("Add text", batch, new TextBuilder(model.Document, batch, _fonts));
        return result with { Overlaps = bottom > shown.Y + shown.Height + 0.01 };
    }

    /// <summary>
    /// Adds a picture inside <paramref name="box"/> (user space), upright on the page as it is shown, centred and
    /// keeping its proportions. JPEG data is embedded as it is; other files go through the editor's <see cref="IImageCodec"/>.
    /// </summary>
    public ObjectEditResult AddImage(PdfRect box, byte[] file)
    {
        if (box.IsEmpty) return new ObjectEditResult(0, [new SkippedObject(-1, EditingText.TooBig)]);
        var model = Model;
        PdfImage? added = file.Length > 2 && file[0] == 0xFF && file[1] == 0xD8 ? PdfImageWriter.AddJpeg(model.Document, file) : null;
        if (added is null && _codec?.DecodeFile(file) is { Count: > 0 } frames && ObjectEditor.Fits(frames[0]))
        {
            added = PdfImageWriter.AddRgba(model.Document, frames[0].Width, frames[0].Height, frames[0].Rgba);
        }
        if (added is null) return new ObjectEditResult(0, [new SkippedObject(-1, EditingText.NoImage)]);

        var geometry = new PageGeometry(model.Page);
        var shown = geometry.ToDisplay(box);
        double scale = Math.Min(shown.Width / added.Width, shown.Height / added.Height);
        double w = added.Width * scale, h = added.Height * scale;
        double x = shown.X + (shown.Width - w) / 2, y = shown.Y + (shown.Height - h) / 2;
        var origin = geometry.ToUser(x, y + h);
        var across = geometry.ToUser(x + w, y + h);
        var up = geometry.ToUser(x, y);
        var matrix = new PdfMatrix(across.X - origin.X, across.Y - origin.Y, up.X - origin.X, up.Y - origin.Y, origin.X, origin.Y);

        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        string name = batch.NewName();
        var writer = new ContentWriter().Paint(name, matrix);
        batch.Append(writer.ToArray(), ("XObject", name, added.Reference));
        batch.Apply();
        _session.Commit("Add picture");
        _model = null;
        return new ObjectEditResult(1, []);
    }

    /// <summary>Adds a straight line from one point to another (user space).</summary>
    public ObjectEditResult AddLine(double x1, double y1, double x2, double y2, ShapeStyle? style = null) =>
        AddShape("Add line", style ?? new ShapeStyle(new RgbColor(0, 0, 0)), w => w.MoveTo(x1, y1).LineTo(x2, y2), stroke: true, fill: false);

    public ObjectEditResult AddRectangle(PdfRect rect, ShapeStyle? style = null)
    {
        style ??= new ShapeStyle(new RgbColor(0, 0, 0));
        return AddShape("Add rectangle", style, w => w.Rect(rect.Left, rect.Bottom, rect.Width, rect.Height), style.Stroke is not null, style.Fill is not null);
    }

    /// <summary>Adds an ellipse that fits the rectangle, drawn with four Bezier curves.</summary>
    public ObjectEditResult AddEllipse(PdfRect rect, ShapeStyle? style = null)
    {
        style ??= new ShapeStyle(new RgbColor(0, 0, 0));
        const double k = 0.5522847498;
        double cx = (rect.Left + rect.Right) / 2, cy = (rect.Bottom + rect.Top) / 2, rx = rect.Width / 2, ry = rect.Height / 2;
        return AddShape("Add ellipse", style, w => w
            .MoveTo(cx + rx, cy)
            .CurveTo(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
            .CurveTo(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
            .CurveTo(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
            .CurveTo(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
            .Close(), style.Stroke is not null, style.Fill is not null);
    }

    private ObjectEditResult AddShape(string label, ShapeStyle style, Action<ContentWriter> path, bool stroke, bool fill)
    {
        if (!stroke && !fill) return new ObjectEditResult(0, [new SkippedObject(-1, EditingText.NothingChanged)]);
        var model = Model;
        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        var w = new ContentWriter().Save();
        var resources = new List<(string, string, PdfObject)>();
        if (style.Opacity < 1)
        {
            var state = new PdfDictionary();
            state["Type"] = new PdfName("ExtGState");
            state["ca"] = new PdfNumber(style.Opacity);
            state["CA"] = new PdfNumber(style.Opacity);
            string name = batch.NewName();
            resources.Add(("ExtGState", name, state));
            w.GraphicsState(name);
        }
        if (style.Stroke is { } s) w.StrokeRgb(s.R / 255.0, s.G / 255.0, s.B / 255.0);
        if (style.Fill is { } f) w.FillRgb(f.R / 255.0, f.G / 255.0, f.B / 255.0);
        w.LineWidth(style.Width);
        path(w);
        w.Op(stroke && fill ? "B" : fill ? "f" : "S");
        w.Restore();
        batch.Append(w.ToArray(), [.. resources]);
        batch.Apply();
        _session.Commit(label);
        _model = null;
        return new ObjectEditResult(1, []);
    }
}
