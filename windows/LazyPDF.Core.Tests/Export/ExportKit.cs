using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

internal sealed class ExportArialSource : IFontSource
{
    public FontFile? Find(string family, FontStyles style)
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        return new FontFile(File.ReadAllBytes(path));
    }
}

/// <summary>Reads PNG and JPEG-less pictures back as a fake system codec would: only what the tests feed it.</summary>
internal sealed class ExportFakeCodec : IImageCodec
{
    public List<string> Decoded { get; } = [];

    public PdfRgbaImage? Decode(byte[] data, string codec)
    {
        Decoded.Add(codec);
        return new PdfRgbaImage(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
    }

    // A "picture file" of the tests is the bytes P, width, height, then width * height gray levels and optionally the two densities as 16 bits.
    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file)
    {
        if (file.Length < 3 || file[0] != (byte)'P') return null;
        int w = file[1], h = file[2];
        var rgba = new byte[w * h * 4];
        for (int i = 0; i < w * h; i++)
        {
            byte g = file[3 + i];
            rgba[4 * i] = rgba[4 * i + 1] = rgba[4 * i + 2] = g;
            rgba[4 * i + 3] = 255;
        }
        int at = 3 + w * h;
        double dpiX = file.Length >= at + 4 ? file[at] << 8 | file[at + 1] : 0, dpiY = file.Length >= at + 4 ? file[at + 2] << 8 | file[at + 3] : 0;
        return [new PdfRgbaImage(w, h, rgba, dpiX, dpiY)];
    }

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [0xFF, 0xD8, (byte)quality, (byte)(image.Rgba[3] == 255 ? 1 : 0), 0xFF, 0xD9];

    public static byte[] Picture(int w, int h, byte gray = 128, int dpiX = 0, int dpiY = 0) =>
        [(byte)'P', (byte)w, (byte)h, .. Enumerable.Repeat(gray, w * h), .. dpiX == 0 && dpiY == 0 ? [] : new[] { (byte)(dpiX >> 8), (byte)dpiX, (byte)(dpiY >> 8), (byte)dpiY }];
}

internal sealed class ExportFakeRenderer(int width, int height, byte alpha = 255) : IPageRenderer
{
    public PdfRgbaImage? Render(int pageIndex, double dpi)
    {
        if (pageIndex < 0 || pageIndex > 1) return null;
        var rgba = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int o = (y * width + x) * 4;
                rgba[o] = (byte)(x * 255 / Math.Max(1, width - 1));
                rgba[o + 1] = (byte)(y * 255 / Math.Max(1, height - 1));
                rgba[o + 2] = (byte)pageIndex;
                rgba[o + 3] = alpha;
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }
}

internal static class ExportKit
{
    /// <summary>An 8 by 6 pixel colour JPEG.</summary>
    public const string SampleJpeg = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z";

    public static byte[] Jpeg => Convert.FromBase64String(SampleJpeg);

    private const string Fonts = "/Font <</F1 10 0 R /F2 11 0 R /F3 12 0 R>> /XObject <</Im1 13 0 R>>";

    public static PdfDocument Open(params string[] pageContents) => PdfDocument.Open(Build(pageContents));

    /// <summary>Pages 612 by 792 with Helvetica as /F1, Helvetica-Bold /F2, Helvetica-Oblique /F3 and the sample JPEG as /Im1.</summary>
    public static byte[] Build(params string[] pageContents)
    {
        int n = pageContents.Length;
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", Enumerable.Range(0, n).Select(i => $"{20 + i} 0 R"))}] /Count {n} /MediaBox [0 0 612 792]>>");
        pdf.Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>");
        pdf.Obj(12, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding>>");
        pdf.Stream(13, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", Jpeg);
        for (int i = 0; i < n; i++)
        {
            pdf.Obj(20 + i, $"<</Type /Page /Parent 2 0 R /Resources <<{Fonts}>> /Contents {40 + i} 0 R>>");
            pdf.Stream(40 + i, "", pageContents[i]);
        }
        return pdf.Finish();
    }

    /// <summary>Three pages of a made-up report: running head and page number, a heading, two paragraphs, a list, a drawn table and a picture.</summary>
    public static PdfDocument Report()
    {
        var pages = Enumerable.Range(1, 3).Select(i => $@"
BT /F1 9 Tf 72 765 Td (Confidential) Tj ET
BT /F1 9 Tf 300 20 Td ({i}) Tj ET
BT /F2 24 Tf 72 700 Td (Annual Report) Tj ET
BT /F1 11 Tf 72 670 Td 14 TL (First line of the opening paragraph that runs on) Tj T* (to a second line and stops there.) Tj ET
BT /F1 11 Tf 72 620 Td (Second paragraph with ) Tj /F2 11 Tf (important) Tj /F3 11 Tf ( words.) Tj ET
BT /F1 11 Tf 72 580 Td (\225) Tj ET BT /F1 11 Tf 90 580 Td (Apples) Tj ET
BT /F1 11 Tf 72 566 Td (\225) Tj ET BT /F1 11 Tf 90 566 Td (Pears) Tj ET
BT /F1 11 Tf 72 540 Td (1. First step) Tj ET
BT /F1 11 Tf 72 526 Td (2. Second step) Tj ET
0.5 w 72 400 m 372 400 l S 72 440 m 372 440 l S 72 480 m 372 480 l S
72 400 m 72 480 l S 222 400 m 222 480 l S 372 400 m 372 480 l S
BT /F1 11 Tf 80 460 Td (Item) Tj ET BT /F1 11 Tf 230 460 Td (Price) Tj ET
BT /F1 11 Tf 80 420 Td (Tea) Tj ET BT /F1 11 Tf 230 420 Td (1,250.50) Tj ET
q 96 0 0 72 72 250 cm /Im1 Do Q").ToArray();
        return Open(pages);
    }

    public static string Unzip(byte[] package, string entry)
    {
        using var zip = new System.IO.Compression.ZipArchive(new MemoryStream(package), System.IO.Compression.ZipArchiveMode.Read);
        using var reader = new StreamReader((zip.GetEntry(entry) ?? throw new InvalidOperationException(entry)).Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }

    public static IReadOnlyList<string> Entries(byte[] package)
    {
        using var zip = new System.IO.Compression.ZipArchive(new MemoryStream(package), System.IO.Compression.ZipArchiveMode.Read);
        return [.. zip.Entries.Select(e => e.FullName)];
    }

    /// <summary>A reader for the PNGs the writer makes: all five filters, 8 bits, gray, RGB or RGBA; chunk CRCs checked.</summary>
    public static (int Width, int Height, byte[] Rgba) PngDecode(byte[] png)
    {
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png[..8]);
        int pos = 8, width = 0, height = 0, type = -1;
        var data = new MemoryStream();
        bool end = false;
        while (pos < png.Length)
        {
            int length = png[pos] << 24 | png[pos + 1] << 16 | png[pos + 2] << 8 | png[pos + 3];
            string name = Encoding.ASCII.GetString(png, pos + 4, 4);
            var body = png.AsSpan(pos + 8, length);
            uint crc = (uint)(png[pos + 8 + length] << 24 | png[pos + 9 + length] << 16 | png[pos + 10 + length] << 8 | png[pos + 11 + length]);
            Assert.Equal(crc, ExportZip.Crc32(body, ExportZip.Crc32(png.AsSpan(pos + 4, 4))));
            if (name == "IHDR")
            {
                width = body[0] << 24 | body[1] << 16 | body[2] << 8 | body[3];
                height = body[4] << 24 | body[5] << 16 | body[6] << 8 | body[7];
                Assert.Equal(8, body[8]);
                type = body[9];
            }
            else if (name == "IDAT") data.Write(body);
            else if (name == "IEND") end = true;
            pos += 12 + length;
        }
        Assert.True(end);
        int channels = type switch { 0 => 1, 2 => 3, 6 => 4, _ => throw new InvalidOperationException("color type " + type) };
        using var inflated = new MemoryStream();
        data.Position = 0;
        using (var z = new System.IO.Compression.ZLibStream(data, System.IO.Compression.CompressionMode.Decompress)) z.CopyTo(inflated);
        var raw = inflated.ToArray();
        int stride = width * channels;
        Assert.Equal(height * (stride + 1), raw.Length);
        var rows = new byte[height * stride];
        for (int y = 0; y < height; y++)
        {
            int filter = raw[y * (stride + 1)];
            for (int i = 0; i < stride; i++)
            {
                int a = i >= channels ? rows[y * stride + i - channels] : 0;
                int b = y > 0 ? rows[(y - 1) * stride + i] : 0;
                int c = i >= channels && y > 0 ? rows[(y - 1) * stride + i - channels] : 0;
                int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
                int predicted = filter switch { 0 => 0, 1 => a, 2 => b, 3 => (a + b) / 2, 4 => pa <= pb && pa <= pc ? a : pb <= pc ? b : c, _ => throw new InvalidOperationException() };
                rows[y * stride + i] = (byte)(raw[y * (stride + 1) + 1 + i] + predicted);
            }
        }
        var rgba = new byte[width * height * 4];
        for (int i = 0; i < width * height; i++)
        {
            rgba[4 * i] = rows[i * channels];
            rgba[4 * i + 1] = rows[i * channels + (channels == 1 ? 0 : 1)];
            rgba[4 * i + 2] = rows[i * channels + (channels == 1 ? 0 : 2)];
            rgba[4 * i + 3] = channels == 4 ? rows[i * channels + 3] : (byte)255;
        }
        return (width, height, rgba);
    }
}
