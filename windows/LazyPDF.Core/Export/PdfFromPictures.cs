using System.Text;

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

    /// <summary>
    /// <paramref name="files"/> are picture files in page order. A JPEG goes into the PDF as its
    /// own bytes, anything else is decoded by the <paramref name="codec"/> (every frame is a page).
    /// A picture is placed at its natural size, which JFIF density gives and 96 dpi otherwise,
    /// shrunk to fit the page inside its margin, never enlarged, centred. EXIF orientation is not applied.
    /// </summary>
    /// <exception cref="ArgumentException">No file could be read, or the margin is negative.</exception>
    public static PicturesPdf Create(IReadOnlyList<byte[]> files, IImageCodec codec, PdfPageSetup? setup = null)
    {
        setup ??= new PdfPageSetup();
        if (!(setup.Margin >= 0)) throw new ArgumentException("The margin cannot be negative.", nameof(setup));
        var document = ExportPdf.NewDocument();
        var pictures = new List<(PdfImage Image, double Dpi)>();
        var unreadable = new List<int>();
        for (int i = 0; i < files.Count; i++)
        {
            int before = pictures.Count;
            if (IsJpeg(files[i]) && PdfImageWriter.AddJpeg(document, files[i]) is { } jpeg)
            {
                pictures.Add((jpeg, JfifDpi(files[i])));
            }
            else if (codec.DecodeFile(files[i]) is { } frames)
            {
                foreach (var frame in frames.Where(f => f.Width > 0 && f.Height > 0 && (long)f.Width * f.Height <= PdfImageSamples.MaxPixels && f.Rgba.Length == (long)f.Width * f.Height * 4))
                    pictures.Add((PdfImageWriter.AddRgba(document, frame.Width, frame.Height, frame.Rgba), DefaultDpi));
            }
            if (pictures.Count == before) unreadable.Add(i);
        }
        if (pictures.Count == 0) throw new ArgumentException(ExportText.NoUsablePicture, nameof(files));

        var sizes = pictures.Select(p => PageSize(setup, p.Image, p.Dpi)).ToList();
        for (int i = 0; i < sizes.Count; i++) PageOperations.InsertBlank(document, i, sizes[i].Width, sizes[i].Height);
        for (int i = 0; i < pictures.Count; i++)
        {
            var (image, dpi) = pictures[i];
            var (width, height) = sizes[i];
            double naturalW = image.Width * 72 / dpi, naturalH = image.Height * 72 / dpi;
            double scale = Math.Min(1, Math.Min((width - 2 * setup.Margin) / naturalW, (height - 2 * setup.Margin) / naturalH));
            double w = naturalW * scale, h = naturalH * scale;
            var page = document.Pages[i];
            string name = ContentResources.Add(document, ContentResources.ForEdit(document, page), "XObject", image.Reference, "Im");
            var content = new ContentWriter().Paint(name, new PdfMatrix(w, 0, 0, h, (width - w) / 2, (height - h) / 2));
            page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), content.ToArray()));
        }
        return new PicturesPdf(document.SaveRewrite(), pictures.Count, unreadable);
    }

    private static (double Width, double Height) PageSize(PdfPageSetup setup, PdfImage image, double dpi)
    {
        double w = image.Width * 72 / dpi, h = image.Height * 72 / dpi;
        if (setup.Paper == PdfPaper.Picture)
            return (Math.Clamp(w + 2 * setup.Margin, 1, MaxPageSide), Math.Clamp(h + 2 * setup.Margin, 1, MaxPageSide));
        return ExportPdf.Paper(setup, landscape: image.Width > image.Height);
    }

    private static bool IsJpeg(byte[] file) => file.Length > 3 && file[0] == 0xFF && file[1] == 0xD8;

    // The density of a JFIF header, when it says dots per inch or per centimetre and is plausible.
    private static double JfifDpi(byte[] file)
    {
        if (file.Length < 18 || file[2] != 0xFF || file[3] != 0xE0 || Encoding.ASCII.GetString(file, 6, 4) != "JFIF") return DefaultDpi;
        int x = file[14] << 8 | file[15];
        double dpi = file[13] switch { 1 => x, 2 => x * 2.54, _ => 0 };
        return dpi is >= 50 and <= 1200 ? dpi : DefaultDpi;
    }
}
