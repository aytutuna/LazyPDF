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

    /// <summary>The /Info names the file keeps for itself, which a custom property cannot use.</summary>
    public static readonly string[] Reserved = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate", "Trapped"];

    /// <summary>Whether a title, author, subject, keywords or custom text that was there is cleared or changed; the old text stays in the file's history.</summary>
    public static bool DropsText(DocumentMetadata before, DocumentMetadata after) =>
        Drops(before.Title, after.Title) || Drops(before.Author, after.Author) ||
        Drops(before.Subject, after.Subject) || Drops(before.Keywords, after.Keywords) ||
        before.Custom.Any(pair => !after.Custom.TryGetValue(pair.Key, out var value) || value != pair.Value);

    /// <summary>Equal in every field, with the custom properties compared by content.</summary>
    public static bool Same(DocumentMetadata a, DocumentMetadata b) =>
        a with { Custom = b.Custom } == b && Sorted(a.Custom).SequenceEqual(Sorted(b.Custom));

    private static IEnumerable<KeyValuePair<string, string>> Sorted(IReadOnlyDictionary<string, string> custom) =>
        custom.OrderBy(pair => pair.Key, StringComparer.Ordinal);

    /// <summary>The custom properties a form holds: trimmed names, the last value of a repeated name, nothing without a value.</summary>
    public static IReadOnlyDictionary<string, string> Custom(IEnumerable<(string Name, string Value)> rows)
    {
        var custom = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, value) in rows)
            if (name.Trim() is { Length: > 0 } key && value.Length > 0) custom[key] = value;
        return custom;
    }

    /// <summary>What stops the properties from being saved, or null.</summary>
    public static string? CustomProblem(IEnumerable<(string Name, string Value)> rows)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var key in rows.Select(row => row.Name.Trim()).Where(name => name.Length > 0))
        {
            if (Reserved.Contains(key)) return Loc.T("{0} is a name the file keeps for itself. Choose another.", key);
            if (key.Any(c => c < ' ' || c > '~')) return Loc.T("{0} has characters a property name cannot hold. Use plain letters, digits and punctuation.", key);
            if (!seen.Add(key)) return Loc.T("Two properties are named {0}.", key);
        }
        return null;
    }

    /// <summary>The note under the custom properties: a problem, or a hint about a property that is left out.</summary>
    public static string? CustomNote(IEnumerable<(string Name, string Value)> rows) =>
        CustomProblem(rows) ?? (rows.Any(row => row.Name.Trim().Length > 0 && row.Value.Length == 0) ? Loc.T("A property with no value is not kept.") : null);

    public static bool ShowDropNotice(bool notify, bool dropped) => notify && dropped;

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
