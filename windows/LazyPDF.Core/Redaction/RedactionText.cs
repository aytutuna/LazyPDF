namespace LazyPDF.Core;

/// <summary>Texts redaction raises to the user.</summary>
public static class RedactionText
{
    public static string NoFont => Loc.T("No font for this text. Pick another font.");
    public static string NothingFound => Loc.T("Nothing was under the marks.");
    public const string ReplacedBy = "[redacted]";
    public static string TextElsewhere => Loc.T("Descriptions, links and names");
    public static string XmpUnreadable => Loc.T("An XMP packet that could not be read");

    public static string Line(PageRedaction p)
    {
        var parts = new List<string>();
        if (p.Glyphs > 0) parts.Add(Loc.Plural(p.Glyphs, "{0} character", "{0} characters"));
        if (p.Images > 0) parts.Add(Loc.Plural(p.Images, "{0} picture", "{0} pictures"));
        if (p.Paths > 0) parts.Add(Loc.Plural(p.Paths, "{0} shape", "{0} shapes"));
        if (p.Annotations > 0) parts.Add(Loc.Plural(p.Annotations, "{0} note", "{0} notes"));
        if (p.Fields > 0) parts.Add(Loc.Plural(p.Fields, "{0} form field", "{0} form fields"));
        return Loc.T("Page {0}: removed {1}.", p.Page + 1, string.Join(", ", parts));
    }

    public static string NeedsPicture(int page) => Loc.T("Page {0} cannot be redacted as text. It needs a page renderer to be turned into a picture.", page + 1);
    public static string NotDrawn(int page) => Loc.T("Page {0} could not be drawn, so it cannot be turned into a picture.", page + 1);
    public static string Flattened(int page) => Loc.T("Page {0} was turned into a picture. Its text can no longer be selected.", page + 1);
    public static string MetadataHolds(string where) => Loc.T("{0} holds removed text.", where);
    public static string MetadataChanged(string where) => Loc.T("{0} held removed text. It was replaced.", where);
    public static string SignaturesGone(int count) => Loc.Plural(count, "The signature is gone.", "{0} signatures are gone.");
    public static string Removed(string text) => Loc.T("Removed: {0}", text);

    public static string StillInside(int page) => Loc.T("Text is still inside a mark on page {0}.", page + 1);
    public static string PageOf(int page) => Loc.T("page {0}|in a sentence", page + 1);
    public static string AttachedFile(int number) => Loc.T("an attached file (object {0})", number);
    public static string NotChecked(string where) => Loc.T("{0} could not be opened, so it was not checked.", where);
    public static string StillInFile(string where) => Loc.T("Removed text is still in {0}.", where);
    public static string NotFollowed(int page) => Loc.T("Page {0} could not be followed to its end, so it was not fully checked.", page + 1);
    public static string TooManyStrings => Loc.T("Not every removed string could be checked.");
    public static string DoesNotOpen => Loc.T("The output does not open.");
}
