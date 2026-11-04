namespace LazyPDF.Core;

/// <summary>Texts redaction raises to the user. Loc.T takes them over when it exists.</summary>
public static class RedactionText
{
    public const string NoFont = "No font for this text. Pick another font.";
    public const string TooBig = "This page is too complex to redact safely.";
    public const string NothingFound = "Nothing was under the marks.";
    public const string ReplacedBy = "[redacted]";
    public const string TextElsewhere = "Descriptions, links and names";
    public const string XmpUnreadable = "An XMP packet that could not be read";

    public static string Line(PageRedaction p)
    {
        var parts = new List<string>();
        Add(parts, p.Glyphs, "character", "characters");
        Add(parts, p.Images, "image", "images");
        Add(parts, p.Paths, "shape", "shapes");
        Add(parts, p.Annotations, "note", "notes");
        Add(parts, p.Fields, "form field", "form fields");
        return $"Page {p.Page + 1}: removed {string.Join(", ", parts)}.";
    }

    private static void Add(List<string> parts, int count, string one, string many)
    {
        if (count > 0) parts.Add($"{count} {(count == 1 ? one : many)}");
    }

    public static string MetadataHolds(string where) => $"{where} holds removed text.";
    public static string MetadataChanged(string where) => $"{where} held removed text. It was replaced.";
    public static string SignaturesGone(int count) => count == 1 ? "The signature is gone." : $"{count} signatures are gone.";
    public static string Removed(string text) => $"Removed: {text}";

    public static string StillInside(int page) => $"Text is still inside a mark on page {page + 1}.";
    public static string AttachedFile(int number) => $"an attached file (object {number})";
    public static string StillInFile(string where) => $"Removed text is still in {where}.";
    public static string NotFollowed(int page) => $"Page {page + 1} could not be followed to its end, so it was not fully checked.";
    public const string TooManyStrings = "Not every removed string could be checked.";
    public const string DoesNotOpen = "The output does not open.";
}
