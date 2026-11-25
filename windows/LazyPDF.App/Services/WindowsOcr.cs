using System.Collections.Concurrent;
using System.Runtime.InteropServices.WindowsRuntime;
using LazyPDF.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using OcrWord = LazyPDF.Core.OcrWord;

namespace LazyPDF.App.Services;

/// <summary>Text recognition on Windows.Media.Ocr, with the languages the user has installed in Windows.</summary>
public sealed class WindowsOcr : ITextRecognizer
{
    /// <summary>True when Windows can recognize <paramref name="language"/> (a BCP 47 tag).</summary>
    public static bool IsAvailable(string language) => Engine(language) is not null;

    public async Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
    {
        var engine = Engine(language) ?? throw new InvalidOperationException(Loc.T("Windows cannot read {0} text yet. Add the language under Settings, Time and language.", language));
        cancellation.ThrowIfCancellationRequested();

        // A picture larger than the engine takes is read smaller and the boxes scaled back.
        double scale = Math.Min(1.0, (double)OcrEngine.MaxImageDimension / Math.Max(image.Width, image.Height));
        int width = (int)Math.Max(1, Math.Round(image.Width * scale)), height = (int)Math.Max(1, Math.Round(image.Height * scale));
        var bitmap = SoftwareBitmap.CreateCopyFromBuffer(Bgra(image, width, height).AsBuffer(), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Ignore);
        var result = await engine.RecognizeAsync(bitmap).AsTask(cancellation);

        var words = new List<OcrWord>();
        double toImage = image.Width / (double)width;
        // TextAngle is how far Windows found the page turned clockwise; the layer wants counter-clockwise radians.
        double angle = result.TextAngle is { } degrees ? -degrees * Math.PI / 180 : 0;
        if (Math.Abs(angle) < MinAngle) angle = 0;
        foreach (var line in result.Lines)
        {
            foreach (var word in line.Words)
            {
                var box = word.BoundingRect;
                var upright = angle == 0 ? new OcrBox(box.X, box.Y, box.Width, box.Height) : Turned(box.X, box.Y, box.Width, box.Height, -angle, width / 2.0, height / 2.0);
                words.Add(new OcrWord(word.Text, new OcrBox(upright.X * toImage, upright.Y * toImage, upright.Width * toImage, upright.Height * toImage), 1, angle));
            }
        }
        return words;
    }

    // Below this (about 0.3 degrees) a page counts as straight, so a clean scan keeps its exact boxes.
    private const double MinAngle = 0.005;

    /// <summary>
    /// Windows gives each word as an upright box in the page turned back by the text angle about the image centre.
    /// This puts its baseline start where the word was printed, keeping the size; <paramref name="clockwise"/> is in radians.
    /// </summary>
    internal static OcrBox Turned(double x, double y, double width, double height, double clockwise, double centerX, double centerY)
    {
        double cos = Math.Cos(clockwise), sin = Math.Sin(clockwise);
        double dx = x - centerX, dy = y + height - centerY;
        double left = centerX + dx * cos - dy * sin, baseline = centerY + dx * sin + dy * cos;
        return new OcrBox(left, baseline - height, width, height);
    }

    // A page can be read four times, so the engine is made once per language. A missing language is asked for again, since it can be added meanwhile.
    private static readonly ConcurrentDictionary<string, OcrEngine> Engines = new();

    /// <summary>The picture turned clockwise by <paramref name="quarterTurns"/> times 90 degrees.</summary>
    internal static PdfRgbaImage Turn(PdfRgbaImage image, int quarterTurns)
    {
        int turns = (quarterTurns % 4 + 4) % 4;
        if (turns == 0) return image;
        int w = image.Width, h = image.Height;
        int width = turns == 2 ? w : h;
        var rgba = new byte[image.Rgba.Length];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                var (tx, ty) = turns switch { 1 => (h - 1 - y, x), 2 => (w - 1 - x, h - 1 - y), _ => (y, w - 1 - x) };
                Array.Copy(image.Rgba, (y * w + x) * 4, rgba, (ty * width + tx) * 4, 4);
            }
        }
        return new PdfRgbaImage(width, turns == 2 ? h : w, rgba);
    }

    private static OcrEngine? Engine(string language)
    {
        if (Engines.TryGetValue(language, out var cached)) return cached;
        try
        {
            var requested = new Language(language);
            var engine = OcrEngine.IsLanguageSupported(requested) ? OcrEngine.TryCreateFromLanguage(requested) : null;
            return engine is null ? null : Engines.GetOrAdd(language, engine);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    // The pixels as BGRA, shrunk to width by height with the nearest pixel when the picture was too large.
    private static byte[] Bgra(PdfRgbaImage image, int width, int height)
    {
        var bgra = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            int sourceRow = Math.Min(image.Height - 1, (int)((y + 0.5) * image.Height / height)) * image.Width;
            for (int x = 0; x < width; x++)
            {
                int from = (sourceRow + Math.Min(image.Width - 1, (int)((x + 0.5) * image.Width / width))) * 4;
                int to = (y * width + x) * 4;
                bgra[to] = image.Rgba[from + 2];
                bgra[to + 1] = image.Rgba[from + 1];
                bgra[to + 2] = image.Rgba[from];
                bgra[to + 3] = 255;
            }
        }
        return bgra;
    }
}
