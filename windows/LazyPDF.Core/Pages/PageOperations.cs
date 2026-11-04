using System.Text;

namespace LazyPDF.Core;

public enum PageBox { Media, Crop, Trim, Bleed, Art }

/// <summary>How <see cref="PageOperations.Resize"/> reaches the new size.</summary>
public enum ResizeMode
{
    /// <summary>The content is scaled to fit, centred; the aspect ratio is kept.</summary>
    ScaleContent,

    /// <summary>The boxes change and the content stays where it is: it is cut off or leaves white space.</summary>
    ChangeBox,
}

/// <summary>
/// Changes to the pages of an open document, made in memory; the caller commits them through
/// <see cref="PdfEditSession.Commit"/>. Pages are named by their index from 0 in the document as it
/// is when the call starts. Anything that changes the set or order of pages leaves the page tree
/// laid out again, so pages held from before the call are stale.
/// </summary>
public static partial class PageOperations
{
    private const double MaxPageSize = 14400;

    private static readonly Dictionary<PageBox, string> BoxKeys = new()
    {
        [PageBox.Media] = "MediaBox", [PageBox.Crop] = "CropBox", [PageBox.Trim] = "TrimBox", [PageBox.Bleed] = "BleedBox", [PageBox.Art] = "ArtBox",
    };

    /// <summary>Turns the pages clockwise by <paramref name="degrees"/>, a multiple of 90 (negative turns back). /Rotate stays 0, 90, 180 or 270.</summary>
    public static void Rotate(PdfDocument document, IEnumerable<int> pages, int degrees)
    {
        if (degrees % 90 != 0) throw new ArgumentException("A page turns in steps of 90 degrees.", nameof(degrees));
        foreach (var page in Select(document, pages))
        {
            page.Dictionary["Rotate"] = new PdfNumber((long)(((page.Rotate + degrees) % 360 + 360) % 360));
        }
    }

    /// <summary>
    /// Sets a box, clipped to the media box (ISO 32000-1 14.11.2), or removes it with null. The media
    /// box cannot be removed. A rectangle with no area, or none inside the media box, is refused.
    /// </summary>
    public static void SetBox(PdfDocument document, IEnumerable<int> pages, PageBox box, PdfRect? rect)
    {
        if (rect is null && box == PageBox.Media) throw new ArgumentException("A page needs a media box.", nameof(rect));
        if (rect is { IsEmpty: true }) throw new ArgumentException("The box has no area.", nameof(rect));
        foreach (var page in Select(document, pages))
        {
            if (rect is not { } value)
            {
                page.Dictionary.Remove(BoxKeys[box]);
                continue;
            }
            var set = box == PageBox.Media ? value : value.Intersect(page.MediaBox);
            if (set.IsEmpty) throw new ArgumentException("The box lies outside the page.", nameof(rect));
            page.Dictionary[BoxKeys[box]] = set.ToArray();
        }
        // A page keeps the values it had when the tree was read, so a removed box would still show.
        if (rect is null) document.RefreshPages();
    }

    /// <summary>
    /// Gives the pages a size in points as they are shown (turned pages included). With
    /// <see cref="ResizeMode.ScaleContent"/> the content, the annotation rectangles and the other
    /// boxes are mapped by a matrix written round the page's content; with
    /// <see cref="ResizeMode.ChangeBox"/> the media and crop boxes become that size from the crop
    /// box's lower-left corner and the trim, bleed and art boxes are removed.
    /// </summary>
    public static void Resize(PdfDocument document, IEnumerable<int> pages, double width, double height, ResizeMode mode)
    {
        if (!(width is > 0 and <= MaxPageSize) || !(height is > 0 and <= MaxPageSize)) throw new ArgumentOutOfRangeException(nameof(width), "The size is out of range.");
        foreach (var page in Select(document, pages))
        {
            var crop = page.CropBox;
            bool turned = page.Rotate % 180 != 0;
            double w = (turned ? height : width) / page.UserUnit, h = (turned ? width : height) / page.UserUnit;
            var dict = page.Dictionary;
            if (mode == ResizeMode.ChangeBox)
            {
                var media = new PdfRect(crop.Left, crop.Bottom, crop.Left + w, crop.Bottom + h);
                dict["MediaBox"] = media.ToArray();
                dict["CropBox"] = media.ToArray();
                foreach (string key in new[] { "TrimBox", "BleedBox", "ArtBox" }) dict.Remove(key);
                continue;
            }
            double s = Math.Min(w / crop.Width, h / crop.Height);
            double e = (w - s * crop.Width) / 2 - s * crop.Left, f = (h - s * crop.Height) / 2 - s * crop.Bottom;
            WrapContents(document, dict, s, e, f);
            MapAnnotations(document, dict, s, e, f);
            var whole = new PdfRect(0, 0, w, h);
            dict["MediaBox"] = whole.ToArray();
            dict["CropBox"] = whole.ToArray();
            foreach (string key in new[] { "TrimBox", "BleedBox", "ArtBox" })
            {
                if (document.Rect(dict[key]) is { } box) dict[key] = new PdfRect(s * box.Left + e, s * box.Bottom + f, s * box.Right + e, s * box.Top + f).ToArray();
                else dict.Remove(key);
            }
        }
    }

    /// <summary>Removes the automatic advance and the transition effect of the pages (ISO 32000-1 12.4.4).</summary>
    public static void RemoveTransitions(PdfDocument document, IEnumerable<int> pages)
    {
        foreach (var page in Select(document, pages))
        {
            page.Dictionary.Remove("Trans");
            page.Dictionary.Remove("Dur");
        }
    }

    private static List<PdfPage> Select(PdfDocument document, IEnumerable<int> indexes)
    {
        var pages = document.Pages;
        var chosen = new List<PdfPage>();
        foreach (int index in indexes.Distinct().Order())
        {
            if ((uint)index >= (uint)pages.Count) throw new ArgumentOutOfRangeException(nameof(indexes), $"There is no page {index + 1}.");
            chosen.Add(pages[index]);
        }
        return chosen;
    }

    private static void WrapContents(PdfDocument document, PdfDictionary page, double s, double e, double f)
    {
        var contents = document.Resolve(page["Contents"]);
        if (contents is null) return;
        var parts = new List<PdfObject>();
        string matrix = $"q {new PdfNumber(s).Text} 0 0 {new PdfNumber(s).Text} {new PdfNumber(e).Text} {new PdfNumber(f).Text} cm\n";
        parts.Add(document.Add(new PdfStream(new PdfDictionary(), Encoding.ASCII.GetBytes(matrix))));
        if (contents is PdfArray array) parts.AddRange(array.Items);
        else parts.Add(page["Contents"]!);
        parts.Add(document.Add(new PdfStream(new PdfDictionary(), "\nQ"u8.ToArray())));
        page["Contents"] = new PdfArray(parts);
    }

    private static void MapAnnotations(PdfDocument document, PdfDictionary page, double s, double e, double f)
    {
        if (document.Array(page, "Annots") is not { } annots) return;
        foreach (var item in annots.Items)
        {
            if (document.Resolve(item) is not PdfDictionary annotation) continue;
            foreach (string key in new[] { "Rect", "QuadPoints", "L", "Vertices", "CL" })
            {
                if (document.Array(annotation, key) is { } points) annotation[key] = Map(document, points, s, e, f);
            }
            if (document.Array(annotation, "InkList") is { } strokes)
            {
                annotation["InkList"] = new PdfArray([.. strokes.Items.Select(i => document.Resolve(i) is PdfArray stroke ? Map(document, stroke, s, e, f) : i)]);
            }
            // /RD is a set of distances, not points: they scale and do not move.
            if (document.Array(annotation, "RD") is { } insets)
            {
                annotation["RD"] = new PdfArray([.. insets.Items.Select(i => document.Resolve(i) is PdfNumber n ? new PdfNumber(s * n.Value) : i)]);
            }
        }
    }

    // Pairs of numbers as points; an array that is not that is left alone.
    private static PdfObject Map(PdfDocument document, PdfArray points, double s, double e, double f)
    {
        var numbers = points.Items.Select(i => document.Resolve(i) as PdfNumber).ToList();
        if (numbers.Count % 2 != 0 || numbers.Any(n => n is null)) return points;
        var mapped = new List<PdfObject>();
        for (int i = 0; i < numbers.Count; i += 2)
        {
            mapped.Add(new PdfNumber(s * numbers[i]!.Value + e));
            mapped.Add(new PdfNumber(s * numbers[i + 1]!.Value + f));
        }
        return new PdfArray(mapped);
    }
}
