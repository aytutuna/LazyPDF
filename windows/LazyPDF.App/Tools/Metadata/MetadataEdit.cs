using LazyPDF.Core;

namespace LazyPDF.App.Tools.Metadata;

/// <summary>Writing the properties and the opening view of a file, and the words for their choices.</summary>
public static class MetadataEdit
{
    public static readonly PageMode[] Modes = Enum.GetValues<PageMode>();

    public static readonly PageLayout[] Layouts = Enum.GetValues<PageLayout>();

    /// <summary>The /Duplex names; null leaves it to the printer.</summary>
    public static readonly string?[] Sides = [null, "Simplex", "DuplexFlipLongEdge", "DuplexFlipShortEdge"];

    /// <summary>Stores both. The changed date becomes <paramref name="now"/> when <paramref name="touchModified"/> is set.</summary>
    public static void Write(PdfDocument document, DocumentMetadata metadata, ViewerSettings view, bool touchModified, DateTimeOffset now)
    {
        (touchModified ? metadata with { Modified = now } : metadata).Write(document);
        view.Write(document);
    }

    /// <summary>Whether a title, author, subject or keywords text that was there is cleared or changed; the old text stays in the file's history.</summary>
    public static bool DropsText(DocumentMetadata before, DocumentMetadata after) =>
        Drops(before.Title, after.Title) || Drops(before.Author, after.Author) ||
        Drops(before.Subject, after.Subject) || Drops(before.Keywords, after.Keywords);

    private static bool Drops(string? before, string? after) => !string.IsNullOrEmpty(before) && before != after;

    public static string ModeName(PageMode mode) => mode switch
    {
        PageMode.UseOutlines => Loc.T("Bookmarks"),
        PageMode.UseThumbs => Loc.T("Page thumbnails"),
        PageMode.FullScreen => Loc.T("Full screen"),
        PageMode.UseOC => Loc.T("Layers"),
        PageMode.UseAttachments => Loc.T("Attachments"),
        _ => Loc.T("Nothing, just the page"),
    };

    public static string LayoutName(PageLayout layout) => layout switch
    {
        PageLayout.OneColumn => Loc.T("Scrolling, one page across"),
        PageLayout.TwoColumnLeft => Loc.T("Scrolling, two pages across"),
        PageLayout.TwoColumnRight => Loc.T("Scrolling, two pages, cover alone"),
        PageLayout.TwoPageLeft => Loc.T("Two pages at a time"),
        PageLayout.TwoPageRight => Loc.T("Two pages at a time, cover alone"),
        _ => Loc.T("One page at a time"),
    };

    public static string SidesName(string? duplex) => duplex switch
    {
        "Simplex" => Loc.T("One side"),
        "DuplexFlipLongEdge" => Loc.T("Both sides, long edge"),
        "DuplexFlipShortEdge" => Loc.T("Both sides, short edge"),
        _ => Loc.T("Printer default"),
    };
}
