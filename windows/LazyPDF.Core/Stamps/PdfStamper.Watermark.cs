namespace LazyPDF.Core;

public sealed partial class PdfStamper
{
    private StampRun Watermark(int id, WatermarkSpec spec)
    {
        bool hasText = !string.IsNullOrEmpty(spec.Text);
        if (hasText == (spec.Image is not null)) throw new ArgumentException(StampsText.NeedsContent);
        var targets = Targets(spec.Pages);
        var font = hasText && targets.Count > 0 ? Font(spec.FontFamily, spec.FontStyle, [spec.Text!]) : null;
        var layer = Layer(id, spec.LayerName);
        var state = Opacity(spec.Opacity);
        var lines = hasText ? spec.Text!.ReplaceLineEndings("\n").Split('\n') : [];
        string oneLine = spec.Text?.ReplaceLineEndings(" ") ?? "";
        string label = hasText ? oneLine[..Math.Min(oneLine.Length, 64)] : "image";

        foreach (int index in targets)
        {
            var page = document.Pages[index];
            var canvas = new StampCanvas(page, id, layer is not null);
            double width = spec.Scale * canvas.Width, height;
            double size = 0;
            if (font is not null)
            {
                double widest = lines.Max(l => font.Width(l, 100));
                size = widest > 0 ? Math.Clamp(width / widest * 100, 1, 1000) : 12;
                width = widest * size / 100;
                height = (lines.Length - 1) * font.LineHeight(size) + (font.Ascent - font.Descent) * size;
            }
            else
            {
                height = width * spec.Image!.Height / spec.Image.Width;
            }
            var (x, y) = Anchored(spec.Anchor, canvas, width, height);
            x += spec.OffsetX;
            y -= spec.OffsetY;

            canvas.BeginArtifact("Pagination", "Watermark");
            canvas.Writer.Save().Concat(StampCanvas.Place(x, y, width, height, spec.Rotation));
            if (state is not null) canvas.Writer.GraphicsState(StampStreams.StateName(id));
            if (font is not null)
            {
                canvas.Writer.FillRgb(spec.Color.R, spec.Color.G, spec.Color.B).BeginText().Font(StampStreams.FontName(id), size);
                for (int i = 0; i < lines.Length; i++)
                {
                    double baseline = height - font.Ascent * size - i * font.LineHeight(size);
                    double left = (width - font.Width(lines[i], size)) / 2;
                    canvas.Writer.TextMatrix(PdfMatrix.Translate(left, baseline)).Show(font, lines[i], size);
                }
                canvas.Writer.EndText();
            }
            else
            {
                canvas.Writer.Paint(StampStreams.ImageName(id), PdfMatrix.Scale(width, height));
            }
            canvas.Writer.Restore();
            canvas.EndArtifact();
            Finish(page, canvas, id, StampKind.Watermark, label, spec.Behind, font?.Reference, spec.Image?.Reference, state, layer);
        }
        return new StampRun(id, targets.Count, 0, font?.Missing ?? []);
    }

    private StampRun Background(int id, BackgroundSpec spec)
    {
        if (spec.Color is null && spec.Image is null) throw new ArgumentException(StampsText.NeedsContent);
        var targets = Targets(spec.Pages);
        var layer = Layer(id, spec.LayerName);
        var state = Opacity(spec.Opacity);

        foreach (int index in targets)
        {
            var page = document.Pages[index];
            var canvas = new StampCanvas(page, id, layer is not null);
            double w = canvas.Width, h = canvas.Height;
            canvas.BeginArtifact("Background", null, page.CropBox);
            canvas.Writer.Save();
            if (state is not null) canvas.Writer.GraphicsState(StampStreams.StateName(id));
            if (spec.Color is { } c) canvas.Writer.FillRgb(c.R, c.G, c.B).Rect(0, 0, w, h).Fill();
            if (spec.Image is { } image)
            {
                double sx = w / image.Width, sy = h / image.Height;
                if (spec.Fit == BackgroundFit.Cover) sx = sy = Math.Max(sx, sy);
                else if (spec.Fit == BackgroundFit.Contain) sx = sy = Math.Min(sx, sy);
                double iw = image.Width * sx, ih = image.Height * sy;
                canvas.Writer.Rect(0, 0, w, h).Clip();
                canvas.Writer.Paint(StampStreams.ImageName(id), new PdfMatrix(iw, 0, 0, ih, (w - iw) / 2, (h - ih) / 2));
            }
            canvas.Writer.Restore();
            canvas.EndArtifact();
            Finish(page, canvas, id, StampKind.Background, null, true, null, spec.Image?.Reference, state, layer);
        }
        return new StampRun(id, targets.Count, 0, []);
    }

    private static (double X, double Y) Anchored(StampAnchor anchor, StampCanvas canvas, double width, double height)
    {
        int column = (int)anchor % 3, row = (int)anchor / 3;
        double x = column switch { 0 => 0, 1 => (canvas.Width - width) / 2, _ => canvas.Width - width };
        double y = row switch { 0 => canvas.Height - height, 1 => (canvas.Height - height) / 2, _ => 0 };
        return (x, y);
    }
}
