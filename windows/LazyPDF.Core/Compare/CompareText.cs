using System.Globalization;

namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class CompareText
{
    public static string KindName(ChangeKind kind) => kind switch
    {
        ChangeKind.Added => "Added",
        ChangeKind.Removed => "Removed",
        ChangeKind.Moved => "Moved",
        _ => "Changed",
    };

    public static string AreaName(ChangeArea area) => area switch
    {
        ChangeArea.Text => "Text",
        ChangeArea.Format => "Format",
        ChangeArea.Image => "Image",
        ChangeArea.Annotation => "Annotation",
        ChangeArea.Page => "Page",
        _ => "Document",
    };

    public static string Title => "Comparison";

    public static string NoDifferences => "No differences found.";

    public static string Pages => "Pages";

    public static string Legend => "Green is added, red is removed, amber is changed or moved.";

    public static string Was => "Was: ";

    public static string MovedFrom(int page) => string.Create(CultureInfo.InvariantCulture, $"Moved from page {page + 1}");

    public static string PageAdded => "Page added";

    public static string PageRemoved => "Page removed";

    public static string PageMoved => "Page moved";

    public static string PageSize(double oldWidth, double oldHeight, double newWidth, double newHeight) =>
        string.Create(CultureInfo.InvariantCulture, $"Size {oldWidth:0.#} x {oldHeight:0.#} pt to {newWidth:0.#} x {newHeight:0.#} pt");

    public static string PageRotation(int from, int to) => $"Rotation {from} to {to} degrees";

    public static string FontChange(string from, string to) => $"Font {from} to {to}";

    public static string SizeChange(double from, double to) => string.Create(CultureInfo.InvariantCulture, $"Size {from:0.##} to {to:0.##}");

    public static string ColorChange(RgbColor from, RgbColor to) => $"Colour {Hex(from)} to {Hex(to)}";

    private static string Hex(RgbColor c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    public static string ImageMoved => "Picture moved or resized";

    public static string ImageReplaced => "Picture replaced";

    public static string AnnotationText => "Comment text";

    public static string AnnotationPosition => "Position";

    public static string AnnotationColor => "Colour";

    public static string Bookmark => "Bookmark";

    public static string BookmarkPage => "Bookmark goes to another page";

    public static string Attachment => "Attachment";

    public static string FormField(string name) => $"Form field {name}";

    public static string Metadata(string field) => field;

    public static string MarksCapped => "Only the first 5000 differences are marked.";

    public static string ChangeCount(int count) => count == 1 ? "1 difference" : string.Create(CultureInfo.InvariantCulture, $"{count} differences");

    public static string PageCounts(int oldCount, int newCount) =>
        string.Create(CultureInfo.InvariantCulture, $"{oldCount} pages and {newCount} pages");
}
