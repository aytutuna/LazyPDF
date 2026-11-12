using System.Globalization;

namespace LazyPDF.Core.Office;

/// <summary>Lays a document out and writes it as a PDF with embedded subset fonts, so the text stays selectable.</summary>
internal static class OfficePdfWriter
{
    /// <summary>Pixels of all pictures in one document that are read; later pictures are skipped.</summary>
    internal const long MaxPicturePixels = 1L << 27;

    /// <param name="contents">When given, receives the content stream of every page as written.</param>
    /// <param name="images">Reads pictures that are not JPEG; without it only JPEG pictures are drawn.</param>
    /// <exception cref="InvalidOperationException">No font can draw the text; the message is <see cref="ExportText.NoFont"/>.</exception>
    /// <exception cref="PdfReadException">The page size or margins leave no room, or the document runs past <see cref="Paginator.MaxPages"/>.</exception>
    public static OfficePdf Create(LayoutDocument document, IFontSource? fonts, CancellationToken cancellation = default, List<byte[]>? contents = null, IImageCodec? images = null)
    {
        var layout = new Paginator(document, new LayoutFonts(fonts), cancellation).Run();
        var pdf = ExportPdf.NewDocument();
        var embedder = new PdfFontEmbedder(pdf, fonts);

        var texts = new Dictionary<(string, FontStyles), List<string>>();
        foreach (var page in layout.Pages)
        {
            foreach (var box in page.Boxes.OfType<PlacedText>())
            {
                if (!texts.TryGetValue((box.Family, box.Style), out var list)) texts[(box.Family, box.Style)] = list = [];
                list.Add(box.Text);
            }
        }
        var pictures = new Dictionary<byte[], PdfImage?>(ReferenceEqualityComparer.Instance);
        int unreadable = 0;
        long pixels = 0;
        foreach (var page in layout.Pages)
        {
            foreach (var box in page.Boxes.OfType<PlacedImage>())
            {
                cancellation.ThrowIfCancellationRequested();
                if (!pictures.TryGetValue(box.Source.Data, out var image))
                {
                    // Pictures come from an untrusted document: past the budget the rest are counted as unreadable, undecoded.
                    image = pixels > MaxPicturePixels ? null : PdfImageWriter.AddPicture(pdf, box.Source.Data, images);
                    if (image is not null) pixels += (long)image.Width * image.Height;
                    pictures[box.Source.Data] = image;
                }
                if (image is null) unreadable++;
            }
        }
        var drawn = new Dictionary<(string, FontStyles), PdfDrawFont>();
        foreach (var ((family, style), list) in texts)
        {
            drawn[(family, style)] = embedder.Add(family, style, list, embed: true) ?? throw new InvalidOperationException(ExportText.NoFont);
        }

        for (int i = 0; i < layout.Pages.Count;)
        {
            int run = 1;
            while (i + run < layout.Pages.Count && layout.Pages[i + run].Width == layout.Pages[i].Width && layout.Pages[i + run].Height == layout.Pages[i].Height) run++;
            PageOperations.InsertBlank(pdf, i, layout.Pages[i].Width, layout.Pages[i].Height, run);
            i += run;
        }
        for (int i = 0; i < layout.Pages.Count; i++)
        {
            cancellation.ThrowIfCancellationRequested();
            byte[] content = Content(pdf, pdf.Pages[i], layout.Pages[i], drawn, pictures);
            contents?.Add(content);
            var dictionary = new PdfDictionary();
            dictionary["Filter"] = new PdfName("FlateDecode");
            pdf.Pages[i].Dictionary["Contents"] = pdf.Add(new PdfStream(dictionary, PdfFilterEncoders.Flate(content)));
        }
        var skipped = layout.Skipped.ToList();
        if (unreadable > 0) skipped.Add(new SkippedFeature(SkippedKinds.UnreadablePicture, unreadable));
        return new OfficePdf(pdf.SaveRewrite(), layout.Pages.Count, skipped, layout.Missing);
    }

    // Everything is rounded to 1/100 point, so that both engines write the same numbers.
    private static double R(double value) => Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0;

    private static double Channel(int value) => Math.Round(value / 255.0 * 1000, MidpointRounding.AwayFromZero) / 1000;

    private static byte[] Content(PdfDocument pdf, PdfPage page, LayoutPage layout, Dictionary<(string, FontStyles), PdfDrawFont> fonts, Dictionary<byte[], PdfImage?> pictures)
    {
        var writer = new ContentWriter();
        var names = new Dictionary<(string, FontStyles), string>();
        var imageNames = new Dictionary<byte[], string>(ReferenceEqualityComparer.Instance);
        var resources = ContentResources.ForEdit(pdf, page);
        int color = -1;
        void Color(int rgb)
        {
            if (rgb == color) return;
            color = rgb;
            writer.FillRgb(Channel(rgb >> 16 & 0xFF), Channel(rgb >> 8 & 0xFF), Channel(rgb & 0xFF));
        }

        foreach (var box in layout.Boxes)
        {
            if (box is PlacedRect rect)
            {
                Color(rect.Color);
                writer.Rect(R(rect.X), R(layout.Height - rect.Y - rect.Height), R(rect.Width), R(rect.Height)).Fill();
            }
            else if (box is PlacedImage picture)
            {
                if (pictures[picture.Source.Data] is not { } image) continue;
                if (!imageNames.TryGetValue(picture.Source.Data, out string? name)) imageNames[picture.Source.Data] = name = ContentResources.Add(pdf, resources, "XObject", image.Reference, "Im");
                Draw(writer, name, picture, layout.Height);
            }
            else if (box is PlacedText text)
            {
                var key = (text.Family, text.Style);
                var font = fonts[key];
                if (!names.TryGetValue(key, out string? name)) names[key] = name = ContentResources.Add(pdf, resources, "Font", font.Reference, "F");
                Color(text.Color);
                writer.BeginText().Font(name, R(text.Size)).MoveText(R(text.X), R(layout.Height - text.Baseline));
                if (text.SpaceExtra > 0) Justified(writer, font, text);
                else writer.Show(font.Encode(text.Text));
                writer.EndText();
            }
        }
        return writer.ToArray();
    }

    // A cropped picture is drawn at the size the whole picture would have and clipped to the visible part.
    private static void Draw(ContentWriter writer, string name, PlacedImage box, double pageHeight)
    {
        var s = box.Source;
        double visibleX = 1 - s.CropLeft - s.CropRight, visibleY = 1 - s.CropTop - s.CropBottom;
        double bottom = pageHeight - box.Y - box.Height;
        if (s.CropLeft + s.CropTop + s.CropRight + s.CropBottom == 0 || visibleX < 0.05 || visibleY < 0.05)
        {
            writer.Paint(name, new PdfMatrix(R(box.Width), 0, 0, R(box.Height), R(box.X), R(bottom)));
            return;
        }
        double width = box.Width / visibleX, height = box.Height / visibleY;
        writer.Save().Rect(R(box.X), R(bottom), R(box.Width), R(box.Height)).Clip();
        writer.Paint(name, new PdfMatrix(R(width), 0, 0, R(height), R(box.X - s.CropLeft * width), R(bottom - s.CropBottom * height)));
        writer.Restore();
    }

    // Tw only works on one-byte codes, so the gap after each space is a TJ adjustment.
    private static void Justified(ContentWriter writer, PdfDrawFont font, PlacedText text)
    {
        var items = new List<PdfObject>();
        double adjust = R(-text.SpaceExtra * 1000 / text.Size);
        int start = 0;
        for (int k = 0; k < text.Text.Length; k++)
        {
            if (text.Text[k] != ' ' || k == text.Text.Length - 1) continue;
            items.Add(new PdfString(font.Encode(text.Text[start..(k + 1)]), isHex: true));
            items.Add(new PdfNumber(adjust));
            start = k + 1;
        }
        items.Add(new PdfString(font.Encode(text.Text[start..]), isHex: true));
        writer.Op("TJ", [new PdfArray(items)]);
    }
}
