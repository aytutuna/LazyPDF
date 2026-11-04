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
        foreach (var line in result.Lines)
        {
            foreach (var word in line.Words)
            {
                var box = word.BoundingRect;
                words.Add(new OcrWord(word.Text, new OcrBox(box.X * toImage, box.Y * toImage, box.Width * toImage, box.Height * toImage)));
            }
        }
        return words;
    }

    private static OcrEngine? Engine(string language)
    {
        try
        {
            var requested = new Language(language);
            return OcrEngine.IsLanguageSupported(requested) ? OcrEngine.TryCreateFromLanguage(requested) : null;
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
