namespace LazyPDF.Core;

/// <summary>The paper a made PDF page has. <see cref="Picture"/> sizes each page to its picture and means A4 for text.</summary>
public enum PdfPaper
{
    A4,
    Letter,
    Picture,
}

public enum PdfOrientation
{
    /// <summary>Landscape for a picture wider than tall; portrait for text.</summary>
    Auto,
    Portrait,
    Landscape,
}

/// <summary>Page size, orientation and margin (points) of a PDF made from pictures or text.</summary>
public sealed record PdfPageSetup(PdfPaper Paper = PdfPaper.A4, PdfOrientation Orientation = PdfOrientation.Auto, double Margin = 36);

/// <summary>A made PDF: its bytes, page count and the files in the list that could not be read (by index).</summary>
public sealed record PicturesPdf(byte[] Bytes, int Pages, IReadOnlyList<int> Unreadable);

/// <summary>A PDF page for each picture or each frame of a picture file.</summary>
public static class PdfFromPictures
{
    private const double MaxPageSide = 14400;
    private const double DefaultDpi = 96;
    private const double MinBox = 1;

    /// <summary>
    /// <paramref name="files"/> are picture files in page order. A JPEG goes into the PDF as its
    /// own bytes, anything else is decoded by the <paramref name="codec"/> (every frame is a page).
    /// A picture is placed at its natural size, which JFIF density gives (each axis its own) and 96 dpi
    /// otherwise, shrunk to fit the page inside its margin, never enlarged, centred. A JPEG's Exif
    /// orientation is applied by the way it is placed, so its bytes stay as they are.
    /// </summary>
    /// <exception cref="ArgumentException">No file could be read, or the margin is negative or leaves no room on the page.</exception>
    public static PicturesPdf Create(IReadOnlyList<byte[]> files, IImageCodec codec, PdfPageSetup? setup = null)
    {
        setup ??= new PdfPageSetup();
        if (!(setup.Margin >= 0)) throw new ArgumentException("The margin cannot be negative.", nameof(setup));
        var document = ExportPdf.NewDocument();
        var pictures = new List<(PdfImage Image, double DpiX, double DpiY, int Orientation)>();
        var unreadable = new List<int>();
        for (int i = 0; i < files.Count; i++)
        {
            int before = pictures.Count;
            if (IsJpeg(files[i]) && PdfImageWriter.AddJpeg(document, files[i]) is { } jpeg)
            {
                var (dpiX, dpiY) = JpegMeta.Density(files[i]);
                pictures.Add((jpeg, dpiX, dpiY, JpegMeta.Orientation(files[i])));
            }
            else if (codec.DecodeFile(files[i]) is { } frames)
            {
                foreach (var frame in frames.Where(f => f.Width > 0 && f.Height > 0 && (long)f.Width * f.Height <= PdfImageSamples.MaxPixels && f.Rgba.Length == (long)f.Width * f.Height * 4))
                    pictures.Add((PdfImageWriter.AddRgba(document, frame.Width, frame.Height, frame.Rgba), DefaultDpi, DefaultDpi, 1));
            }
            if (pictures.Count == before) unreadable.Add(i);
        }
        if (pictures.Count == 0) throw new ArgumentException(ExportText.NoUsablePicture, nameof(files));

        var natural = pictures.Select(Natural).ToList();
        var sizes = natural.Select(n => PageSize(setup, n.Width, n.Height)).ToList();
        // Picture paper is the picture plus margins, so a tiny picture is room enough; only the clamp can take it away.
        double least = setup.Paper == PdfPaper.Picture ? double.Epsilon : MinBox;
        if (sizes.Any(s => s.Width - 2 * setup.Margin < least || s.Height - 2 * setup.Margin < least))
            throw new ArgumentException("The margin leaves no room on the page.", nameof(setup));
        for (int i = 0; i < sizes.Count; i++) PageOperations.InsertBlank(document, i, sizes[i].Width, sizes[i].Height);
        for (int i = 0; i < pictures.Count; i++)
        {
            var (image, _, _, orientation) = pictures[i];
            var (width, height) = sizes[i];
            var (naturalW, naturalH) = natural[i];
            double scale = Math.Min(1, Math.Min((width - 2 * setup.Margin) / naturalW, (height - 2 * setup.Margin) / naturalH));
            double w = naturalW * scale, h = naturalH * scale;
            var page = document.Pages[i];
            string name = ContentResources.Add(document, ContentResources.ForEdit(document, page), "XObject", image.Reference, "Im");
            var content = new ContentWriter().Paint(name, JpegMeta.Placement(orientation, w, h, (width - w) / 2, (height - h) / 2));
            page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), content.ToArray()));
        }
        return new PicturesPdf(document.SaveRewrite(), pictures.Count, unreadable);
    }

    // The size on the page, after the picture is turned.
    private static (double Width, double Height) Natural((PdfImage Image, double DpiX, double DpiY, int Orientation) p)
    {
        double w = p.Image.Width * 72 / p.DpiX, h = p.Image.Height * 72 / p.DpiY;
        return p.Orientation >= 5 ? (h, w) : (w, h);
    }

    private static (double Width, double Height) PageSize(PdfPageSetup setup, double w, double h)
    {
        if (setup.Paper == PdfPaper.Picture)
            return (Math.Clamp(w + 2 * setup.Margin, 1, MaxPageSide), Math.Clamp(h + 2 * setup.Margin, 1, MaxPageSide));
        return ExportPdf.Paper(setup, landscape: w > h);
    }

    private static bool IsJpeg(byte[] file) => file.Length > 3 && file[0] == 0xFF && file[1] == 0xD8;
}
