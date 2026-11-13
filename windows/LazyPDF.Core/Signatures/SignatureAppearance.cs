using System.Globalization;

namespace LazyPDF.Core;

// The appearance of a visible signature: a form XObject with the picture or ink on the left, the text beside it.
internal static class SignatureAppearance
{
    private const double Margin = 3;

    public static string Text(SignJob job, SignatureLook look)
    {
        if (look.Text is { } given) return given;
        var lines = new List<string>
        {
            $"{SignatureText.SignedBy} {job.Name}",
            $"{SignatureText.DatePrefix} {job.Request.Time.ToString("yyyy-MM-dd HH:mm zzz", CultureInfo.InvariantCulture)}",
        };
        if (job.Reason is { Length: > 0 } reason) lines.Add($"{SignatureText.ReasonPrefix} {reason}");
        if (job.Request.Location is { Length: > 0 } location) lines.Add($"{SignatureText.LocationPrefix} {location}");
        return string.Join('\n', lines);
    }

    /// <summary>The font for the text, found before anything is added to the document; null when there is no text.</summary>
    public static PdfDrawFont? AddFont(PdfDocument document, SignJob job, SignatureLook look, string text)
    {
        if (text.Length == 0) return null;
        return new PdfFontEmbedder(document, job.Request.Fonts).Add(look.FontFamily, FontStyles.Regular, [text])
               ?? throw new InvalidOperationException(SignatureText.NoFont);
    }

    /// <summary>
    /// The appearance for a widget at <paramref name="rect"/> on a page turned <paramref name="rotate"/> degrees clockwise: it is drawn
    /// upright as the page is shown, and its /Matrix turns it back into the page's own space (12.5.5).
    /// </summary>
    public static PdfReference Draw(PdfDocument document, PdfRect rect, int rotate, SignatureLook look, string text, PdfDrawFont? font)
    {
        bool sideways = rotate is 90 or 270;
        double width = sideways ? rect.Height : rect.Width, height = sideways ? rect.Width : rect.Height;
        var canvas = new AppearanceCanvas(document, new PdfRect(0, 0, width, height));
        bool hasImage = look.Jpeg is not null || look.Image is not null;
        bool hasInk = look.Ink is { Count: > 0 };
        double graphicsWidth = (hasImage || hasInk) ? (font is null ? width : width * 0.4) : 0;

        if (hasImage)
        {
            var image = look.Jpeg is not null ? PdfImageWriter.AddJpeg(document, look.Jpeg) : null;
            image ??= look.Image is { } rgba ? PdfImageWriter.AddRgba(document, rgba.Width, rgba.Height, rgba.Rgba) : null;
            if (image is not null)
            {
                double scale = Math.Min((graphicsWidth - 2 * Margin) / image.Width, (height - 2 * Margin) / image.Height);
                double w = image.Width * scale, h = image.Height * scale;
                string name = canvas.AddXObject(image.Reference);
                canvas.W.Paint(name, new PdfMatrix(w, 0, 0, h, (graphicsWidth - w) / 2, (height - h) / 2));
            }
        }
        else if (hasInk)
        {
            double side = Math.Min(graphicsWidth, height) - 2 * Margin;
            double left = (graphicsWidth - side) / 2, bottom = (height - side) / 2;
            canvas.W.Save().StrokeRgb(0, 0, 0.5).LineWidth(1.2).Op("J", 1).Op("j", 1);
            foreach (var stroke in look.Ink!)
            {
                for (int i = 0; i < stroke.Count; i++)
                {
                    double x = left + Math.Clamp(stroke[i].X, 0, 1) * side, y = bottom + Math.Clamp(stroke[i].Y, 0, 1) * side;
                    if (i == 0) canvas.W.MoveTo(x, y);
                    else canvas.W.LineTo(x, y);
                }
                if (stroke.Count == 1) canvas.W.LineTo(left + stroke[0].X * side + 0.1, bottom + stroke[0].Y * side);
                canvas.W.Stroke();
            }
            canvas.W.Restore();
        }

        if (font is not null) DrawText(canvas, font, text, graphicsWidth + Margin, width - graphicsWidth - 2 * Margin, height - 2 * Margin);
        var form = canvas.ToStream();
        if (rotate != 0) form.Dictionary["Matrix"] = Turn(rotate);
        return document.Add(form);
    }

    private static PdfArray Turn(int degrees)
    {
        (int a, int b) = degrees switch { 90 => (0, 1), 180 => (-1, 0), _ => (0, -1) };
        return new PdfArray([new PdfNumber(a), new PdfNumber(b), new PdfNumber(-b), new PdfNumber(a), new PdfNumber(0), new PdfNumber(0)]);
    }

    private static void DrawText(AppearanceCanvas canvas, PdfDrawFont font, string text, double left, double width, double height)
    {
        double size = 12;
        IReadOnlyList<string> lines = font.Wrap(text, size, width);
        while (size > 4 && lines.Count * font.LineHeight(size) > height)
        {
            size -= 0.5;
            lines = font.Wrap(text, size, width);
        }
        string name = canvas.AddFont(font.Reference);
        double lineHeight = font.LineHeight(size);
        double top = Margin + height - font.Ascent * size;
        canvas.W.BeginText().Font(name, size).FillGray(0).MoveText(left, top);
        for (int i = 0; i < lines.Count; i++)
        {
            if (i > 0) canvas.W.MoveText(0, -lineHeight);
            canvas.W.Show(font, lines[i], size);
        }
        canvas.W.EndText();
    }
}
