using System.Text;

namespace LazyPDF.Core;

/// <summary>What a JPEG file says about how it is to be shown: JFIF density and Exif orientation.</summary>
internal static class JpegMeta
{
    private const double DefaultDpi = 96;

    // The density of a JFIF header, when it says dots per inch or per centimetre and is plausible.
    public static (double X, double Y) Density(byte[] file)
    {
        if (file.Length < 18 || file[2] != 0xFF || file[3] != 0xE0 || Encoding.ASCII.GetString(file, 6, 4) != "JFIF") return (DefaultDpi, DefaultDpi);
        double unit = file[13] switch { 1 => 1, 2 => 2.54, _ => 0 };
        double x = unit * (file[14] << 8 | file[15]), y = unit * (file[16] << 8 | file[17]);
        return x is >= 50 and <= 1200 && y is >= 50 and <= 1200 ? (x, y) : (DefaultDpi, DefaultDpi);
    }

    /// <summary>The Exif orientation (1 to 8, tag 0x0112 of the first IFD); 1 when there is none.</summary>
    public static int Orientation(byte[] file)
    {
        int p = 2;
        while (p + 4 <= file.Length && file[p] == 0xFF && file[p + 1] is not (0xDA or 0xD9))
        {
            int length = file[p + 2] << 8 | file[p + 3];
            int end = Math.Min(file.Length, p + 2 + length);
            if (file[p + 1] == 0xE1 && end - p >= 18 && Encoding.ASCII.GetString(file, p + 4, 4) == "Exif") return Tiff(file, p + 10, end);
            p += 2 + length;
        }
        return 1;
    }

    private static int Tiff(byte[] file, int start, int end)
    {
        bool big = file[start] == 'M';
        if (file[start] != (big ? 'M' : 'I') || file[start + 1] != file[start]) return 1;
        int U16(int at) => big ? file[at] << 8 | file[at + 1] : file[at + 1] << 8 | file[at];
        long U32(int at) => big ? (long)U16(at) << 16 | (uint)U16(at + 2) : (long)U16(at + 2) << 16 | (uint)U16(at);
        long ifd = start + U32(start + 4);
        if (ifd + 2 > end) return 1;
        int count = U16((int)ifd);
        for (int i = 0; i < count && ifd + 2 + 12 * (i + 1) <= end; i++)
        {
            int entry = (int)ifd + 2 + 12 * i;
            if (U16(entry) != 0x0112) continue;
            int value = U16(entry + 8);
            return value is >= 1 and <= 8 ? value : 1;
        }
        return 1;
    }

    /// <summary>
    /// Where the unit square of an image goes so that it shows with <paramref name="orientation"/> undone
    /// in a box of <paramref name="w"/> by <paramref name="h"/> whose lower left corner is at (<paramref name="x"/>, <paramref name="y"/>).
    /// </summary>
    public static PdfMatrix Placement(int orientation, double w, double h, double x, double y)
    {
        // Shown position as (xa u + xb t + xc, ya u + yb t + yc) of the column u and row t, both from 0 to 1 and t downwards.
        var (xa, xb, xc, ya, yb, yc) = orientation switch
        {
            2 => (-1, 0, 1, 0, 1, 0),
            3 => (-1, 0, 1, 0, -1, 1),
            4 => (1, 0, 0, 0, -1, 1),
            5 => (0, 1, 0, 1, 0, 0),
            6 => (0, -1, 1, 1, 0, 0),
            7 => (0, -1, 1, -1, 0, 1),
            8 => (0, 1, 0, -1, 0, 1),
            _ => (1, 0, 0, 0, 1, 0),
        };
        return new PdfMatrix(w * xa, -h * ya, -w * xb, h * yb, x + w * (xb + xc), y + h * (1 - yb - yc));
    }

    /// <summary>The pixels turned and mirrored so that <paramref name="orientation"/> is undone; 5 to 8 swap width and height.</summary>
    public static PdfRgbaImage Upright(PdfRgbaImage image, int orientation)
    {
        if (orientation is < 2 or > 8) return image;
        int w = image.Width, h = image.Height;
        bool swap = orientation >= 5;
        int dw = swap ? h : w;
        var rgba = new byte[image.Rgba.Length];
        for (int r = 0; r < h; r++)
        {
            for (int c = 0; c < w; c++)
            {
                var (x, y) = orientation switch
                {
                    2 => (w - 1 - c, r),
                    3 => (w - 1 - c, h - 1 - r),
                    4 => (c, h - 1 - r),
                    5 => (r, c),
                    6 => (h - 1 - r, c),
                    7 => (h - 1 - r, w - 1 - c),
                    _ => (r, w - 1 - c),
                };
                Array.Copy(image.Rgba, 4 * (r * w + c), rgba, 4 * (y * dw + x), 4);
            }
        }
        return new PdfRgbaImage(dw, swap ? w : h, rgba);
    }
}