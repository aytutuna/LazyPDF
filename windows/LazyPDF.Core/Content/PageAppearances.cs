namespace LazyPDF.Core;

// The normal appearances of a page's annotations, each with the matrix that carries it onto the
// annotation's /Rect.
internal static class PageAppearances
{
    /// <summary>With <paramref name="shownOnly"/>, annotations that are hidden, not for viewing, or popups are left out.</summary>
    public static IEnumerable<(PdfStream Form, PdfMatrix Matrix)> Of(PdfDocument document, PdfPage page, bool shownOnly = false)
    {
        foreach (var item in document.Array(page.Dictionary, "Annots")?.Items ?? [])
        {
            if (document.Resolve(item) is not PdfDictionary annotation || document.Rect(annotation, "Rect") is not { } rect) continue;
            if (shownOnly && (((document.Integer(annotation, "F") ?? 0) & 0b100010) != 0 || document.Name(annotation, "Subtype") == "Popup")) continue;
            var normal = document.Resolve(document.Dict(annotation, "AP")?["N"]);
            var form = normal as PdfStream;
            if (normal is PdfDictionary states && document.Name(annotation, "AS") is { } state) form = document.Resolve(states[state]) as PdfStream;
            if (form is null || document.Rect(form.Dictionary, "BBox") is not { } box) continue;
            var own = PdfMatrix.FromArray(document.Array(form.Dictionary, "Matrix"), document.Resolve) ?? PdfMatrix.Identity;
            var moved = own.Transform(box);
            if (moved.Width < 1e-6 || moved.Height < 1e-6) continue;
            double sx = rect.Width / moved.Width, sy = rect.Height / moved.Height;
            yield return (form, new PdfMatrix(sx, 0, 0, sy, rect.Left - moved.Left * sx, rect.Bottom - moved.Bottom * sy));
        }
    }
}
