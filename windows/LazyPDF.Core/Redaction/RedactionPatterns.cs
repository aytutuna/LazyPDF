namespace LazyPDF.Core;

/// <summary>
/// Which patterns can paint under a mark without holding anything that was on the page (ISO 32000-1 8.7): an axial or
/// radial shading. A tiling cell is a drawing of its own, a signature or a picture made of small shapes, and taking the
/// path under the mark out of the page leaves the cell in the file; a mesh and a pattern with a graphics state of its
/// own can hold the marked thing too. A page that paints one under a mark is not redacted in place.
/// </summary>
internal static class RedactionPatterns
{
    public static bool Plain(PdfDocument document, PdfObject pattern) =>
        pattern is PdfDictionary shaded && document.Integer(shaded, "PatternType") == 2 && !shaded.ContainsKey("ExtGState")
        && document.Integer(document.Resolve(shaded["Shading"]) as PdfDictionary, "ShadingType") is 2 or 3;
}
