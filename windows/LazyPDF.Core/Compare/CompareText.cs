using System.Globalization;

namespace LazyPDF.Core;

public static class CompareText
{
    public static string KindName(ChangeKind kind) => kind switch
    {
        ChangeKind.Added => Loc.T("Added"),
        ChangeKind.Removed => Loc.T("Removed"),
        ChangeKind.Moved => Loc.T("Moved"),
        _ => Loc.T("Changed"),
    };

    public static string AreaName(ChangeArea area) => area switch
    {
        ChangeArea.Text => Loc.T("Text"),
        ChangeArea.Format => Loc.T("Format"),
        ChangeArea.Image => Loc.T("Picture"),
        ChangeArea.Annotation => Loc.T("Annotation"),
        ChangeArea.Page => Loc.T("Page"),
        _ => Loc.T("Document"),
    };

    public static string Title => Loc.T("Comparison");

    public static string NoDifferences => Loc.T("No differences found.");

    public static string Pages => Loc.T("Pages");

    public static string Legend => Loc.T("Green is added, red is removed, amber is changed or moved.");

    public static string Was => Loc.T("Was: ");

    public static string MovedFrom(int page) => Loc.T("Moved from page {0}", page + 1);

    public static string PageAdded => Loc.T("Page added");

    public static string PageRemoved => Loc.T("Page removed");

    public static string PageMoved => Loc.T("Page moved");

    public static string PageSize(double oldWidth, double oldHeight, double newWidth, double newHeight) =>
        Loc.T("Size {0} x {1} pt to {2} x {3} pt", Points(oldWidth), Points(oldHeight), Points(newWidth), Points(newHeight));

    private static string Points(double value) => value.ToString("0.#", CultureInfo.InvariantCulture);

    public static string PageRotation(int from, int to) => Loc.T("Rotation {0} to {1} degrees", from, to);

    public static string FontChange(string from, string to) => Loc.T("Font {0} to {1}", from, to);

    public static string SizeChange(double from, double to) =>
        Loc.T("Size {0} to {1}", from.ToString("0.##", CultureInfo.InvariantCulture), to.ToString("0.##", CultureInfo.InvariantCulture));

    public static string ColorChange(RgbColor from, RgbColor to) => Loc.T("Color {0} to {1}", Hex(from), Hex(to));

    private static string Hex(RgbColor c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    public static string ImageMoved => Loc.T("Picture moved or resized");

    public static string ImageReplaced => Loc.T("Picture replaced");

    public static string AnnotationText => Loc.T("Comment text");

    public static string AnnotationPosition => Loc.T("Position");

    public static string AnnotationColor => Loc.T("Color");

    public static string Bookmark => Loc.T("Bookmark");

    public static string BookmarkPage => Loc.T("Bookmark goes to another page");

    public static string Attachment => Loc.T("Attachment");

    public static string FormField(string name) => Loc.T("Form field {0}", name);

    public static string Metadata(string field) => field;

    public static string MarksCapped => Loc.T("Only the first 5000 differences are marked.");

    public static string ChangeCount(int count) => Loc.Plural(count, "{0} difference", "{0} differences");

    public static string PageCounts(int oldCount, int newCount) =>
        Loc.T("{0} pages and {1} pages", oldCount, newCount);
}
