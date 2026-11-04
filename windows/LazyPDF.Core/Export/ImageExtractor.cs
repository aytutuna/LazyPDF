namespace LazyPDF.Core;

/// <summary>An image a page paints, as a file: JPEG as its own bytes, anything else as PNG.</summary>
/// <param name="PageIndex">From 0.</param>
/// <param name="Name">The resource name on the page ("Im1"), or "inline1" for an inline image.</param>
public sealed record ExportedImage(int PageIndex, string Name, ExportImage Image)
{
    /// <summary>"page3_Im1.jpg".</summary>
    public string FileName => $"page{PageIndex + 1}_{Name}.{Image.Extension}";
}

public static class ImageExtractor
{
    /// <summary>
    /// Every image the pages paint, forms included, in painting order; one the page paints twice
    /// is listed once. JPEG data is kept as stored, other images go to PNG with an /SMask as alpha.
    /// Without a <paramref name="codec"/> the JPEG 2000 and JBIG2 images, and JPEGs that need
    /// their mask merged, are not decoded: the first is left out, the second kept as plain JPEG.
    /// </summary>
    public static IReadOnlyList<ExportedImage> Extract(PdfDocument document, IReadOnlyList<int>? pages = null, IImageCodec? codec = null, CancellationToken cancel = default)
    {
        var images = new ExportImages(document, codec);
        var interpreter = new ContentInterpreter(document) { WalkPatterns = false };
        var found = new List<ExportedImage>();
        foreach (int index in pages ?? Enumerable.Range(0, document.Pages.Count).ToList())
        {
            cancel.ThrowIfCancellationRequested();
            if (index < 0 || index >= document.Pages.Count) throw new ArgumentOutOfRangeException(nameof(pages));
            var scan = new ExportScan(new PageGeometry(document.Pages[index]), false);
            interpreter.Run(document.Pages[index], scan);
            var seen = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
            var names = new HashSet<string>();
            int inline = 0;
            foreach (var info in scan.Images)
            {
                if (info.Stream is { } stream && !seen.Add(stream)) continue;
                if (images.Get(info) is not { } image) continue;
                string name = info.Name ?? $"inline{++inline}", unique = name;
                for (int n = 2; !names.Add(unique); n++) unique = $"{name}_{n}";
                found.Add(new ExportedImage(index, unique, image));
            }
        }
        return found;
    }
}
