namespace LazyPDF.Core;

/// <summary>What a page holds, as far as OCR is concerned.</summary>
public enum OcrPageKind
{
    /// <summary>Nothing is drawn.</summary>
    Blank,
    /// <summary>Paths or small pictures and no text: outlined text, a drawing.</summary>
    Drawing,
    /// <summary>A picture covers most of the page and any text on it is a stamp or a number.</summary>
    Picture,
    /// <summary>The page has the layer <see cref="PdfOcrLayer"/> wrote, whatever else it shows.</summary>
    OwnLayer,
    /// <summary>The only text is invisible and not ours: an earlier OCR by another tool.</summary>
    ForeignLayer,
    /// <summary>The page has text a person can see.</summary>
    Text,
}

/// <summary>Decides which pages OCR is for. One pass of the content interpreter over each page.</summary>
public static class OcrTriage
{
    /// <summary>A picture this share of the page, or more, makes it a scan.</summary>
    public const double PictureShare = 0.6;

    /// <summary>Visible text covering less than this share of a page with a picture on it does not count as text.</summary>
    public const double SparseTextShare = 0.02;

    public static OcrPageKind Classify(PdfDocument document, PdfPage page) => Classify(document, page, new ContentInterpreter(document));

    public static IReadOnlyList<OcrPageKind> ClassifyAll(PdfDocument document)
    {
        var interpreter = new ContentInterpreter(document);
        return [.. document.Pages.Select(p => Classify(document, p, interpreter))];
    }

    /// <summary>Whether a page of this kind is to be read: pictures and drawings always, an own layer when it is to be replaced, text and foreign layers only when forced, blank pages only when forced.</summary>
    public static bool NeedsOcr(OcrPageKind kind, bool replaceOwnLayer, bool force) => kind switch
    {
        OcrPageKind.Picture or OcrPageKind.Drawing => true,
        OcrPageKind.OwnLayer => replaceOwnLayer,
        _ => force,
    };

    internal static OcrPageKind Classify(PdfDocument document, PdfPage page, ContentInterpreter interpreter)
    {
        var survey = new Survey(page.CropBox);
        interpreter.Run(page, survey);
        double area = page.CropBox.Width * page.CropBox.Height;
        bool picture = area > 0 && survey.PictureArea / area >= PictureShare;
        bool visibleText = survey.Visible > 0 && !(picture && survey.TextArea / area < SparseTextShare);
        if (PdfOcrLayer.Has(document, page)) return OcrPageKind.OwnLayer;
        if (visibleText) return OcrPageKind.Text;
        if (survey.Invisible > 0) return OcrPageKind.ForeignLayer;
        if (picture) return OcrPageKind.Picture;
        return survey.Marks > 0 ? OcrPageKind.Drawing : OcrPageKind.Blank;
    }

    private sealed class Survey(PdfRect crop) : ContentVisitor
    {
        public int Visible, Invisible, Marks;
        public double TextArea, PictureArea;

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            int mode = context.State.RenderMode;
            if (mode == 3)
            {
                Invisible++;
                return;
            }
            if (mode == 7 || (glyph.Unicode is { } text && string.IsNullOrWhiteSpace(text))) return;
            Visible++;
            TextArea += glyph.Bounds.Intersect(crop) is { IsEmpty: false } box ? box.Width * box.Height : 0;
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            Marks++;
            if (image.Bounds.Intersect(crop) is { IsEmpty: false } box) PictureArea += box.Width * box.Height;
        }

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke) Marks++;
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading) => Marks++;
    }
}
