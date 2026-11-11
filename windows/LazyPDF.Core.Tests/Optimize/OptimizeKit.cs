using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class OptimizeKit
{
    public static readonly byte[] TinyJpeg = Convert.FromBase64String(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQ" +
        "ERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" +
        "FBQUFBQUFBQUFBQUFBT/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA" +
        "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6" +
        "Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG" +
        "x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA" +
        "AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5" +
        "OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPE" +
        "xcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5V8KfCn7n7n9K9m8J/Cn7n7n9K9i8J/Cn" +
        "7n7n9K9m8KfCn7n7n9K6854w394nw249+D3+x//Z");

    /// <summary>The options with every step off, so that a test turns on the one it is about.</summary>
    public static readonly OptimizeOptions Off = new()
    {
        ObjectStreams = false, RecompressStreams = false, ConvertOldFilters = false, RemoveDuplicates = false,
        StripThumbnails = false, StripPieceInfo = false, PruneResources = false,
    };

    /// <summary>A one-page file (200 by 200); the content is object 4 and <paramref name="more"/> adds objects from 5 on. With <paramref name="shared"/> the resources are object 12.</summary>
    public static byte[] Build(string content, string resources = "", Action<TestPdf>? more = null, string pageExtra = "", string catalogExtra = "", string contents = "4 0 R", bool shared = false)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents {contents} /Resources {(shared ? "12 0 R" : $"<<{resources}>>")} {pageExtra}>>");
        if (shared) pdf.Obj(12, $"<<{resources}>>");
        pdf.Stream(4, "", content);
        more?.Invoke(pdf);
        return pdf.Finish();
    }

    /// <summary>Opens the file in PdfPig and returns its text; fails the test when PdfPig cannot read it.</summary>
    public static string PigText(byte[] file)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(file);
        return string.Join("\n", pig.GetPages().Select(p => p.Text));
    }

    public static int PigPages(byte[] file)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(file);
        return pig.NumberOfPages;
    }

    /// <summary>The text of every page as the engine reads it.</summary>
    public static string EngineText(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        var cache = new TextCache(document);
        return string.Join("\f", Enumerable.Range(0, document.Pages.Count).Select(i => cache.Get(i).Text));
    }

    /// <summary>Whether the marker is in the bytes of the file, or in the data of any stream once decoded.</summary>
    public static bool Everywhere(byte[] file, string marker)
    {
        byte[] needle = Encoding.Latin1.GetBytes(marker);
        byte[] wide = Encoding.BigEndianUnicode.GetBytes(marker);
        if (file.AsSpan().IndexOf(needle) >= 0 || file.AsSpan().IndexOf(wide) >= 0) return true;
        using var document = PdfDocument.Open(file);
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not PdfStream stream) continue;
            try
            {
                var data = document.Data(stream);
                if (data.AsSpan().IndexOf(needle) >= 0 || data.AsSpan().IndexOf(wide) >= 0) return true;
            }
            catch (PdfReadException)
            {
            }
        }
        return false;
    }

    public static PdfStream Image(PdfDocument document, string name = "Im0")
    {
        var page = document.Pages[0];
        var xobjects = document.Dict(page.Resources, "XObject")!;
        return (PdfStream)document.Resolve(xobjects[name])!;
    }

    public static int Count(PdfDocument document, Func<PdfObject, bool> match) =>
        document.ObjectNumbers.Count(n => document.Get(n) is { } o && match(o));

    public static bool IsImage(PdfDocument document, PdfObject o) => o is PdfStream s && document.Name(s.Dictionary, "Subtype") == "Image";

    /// <summary>Samples of a stream with its filters undone.</summary>
    public static byte[] Decoded(PdfDocument document, PdfStream stream) => document.Data(stream);

    public static byte[] Noise(int length, int seed = 1)
    {
        var data = new byte[length];
        new Random(seed).NextBytes(data);
        return data;
    }

    /// <summary>RGB samples with a smooth gradient, so that they deflate well but are not flat.</summary>
    public static byte[] Gradient(int width, int height, int components)
    {
        var data = new byte[width * height * components];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                for (int c = 0; c < components; c++) data[(y * width + x) * components + c] = (byte)((x * 255 / Math.Max(1, width - 1) + y * c * 40 / Math.Max(1, height)) & 0xFF);
            }
        }
        return data;
    }
}

/// <summary>Stands for the system codecs: reads the size from a JPEG header and answers with a gradient.</summary>
internal sealed class OptimizeFakeCodec : IImageCodec
{
    public int Decodes { get; private set; }
    public Action? OnDecode { get; init; }
    public int LastQuality { get; private set; }
    public PdfRgbaImage? LastEncoded { get; private set; }

    public PdfRgbaImage? Decode(byte[] data, string codec)
    {
        Decodes++;
        OnDecode?.Invoke();
        int at = data.AsSpan().IndexOf(new byte[] { 0xFF, 0xC0 });
        if (at < 0) return null;
        int height = data[at + 5] << 8 | data[at + 6], width = data[at + 7] << 8 | data[at + 8];
        var rgba = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int o = (y * width + x) * 4;
                (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = ((byte)(x * 255 / Math.Max(1, width - 1)), (byte)(y * 255 / Math.Max(1, height - 1)), 128, 255);
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }

    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => null;

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality)
    {
        LastQuality = quality;
        LastEncoded = image;
        var data = new byte[24 + image.Width * image.Height * quality / 100];
        (data[0], data[1]) = (0xFF, 0xD8);
        (data[^2], data[^1]) = (0xFF, 0xD9);
        return data;
    }
}
