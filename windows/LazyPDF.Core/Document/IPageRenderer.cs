namespace LazyPDF.Core;

/// <summary>
/// Draws the pages of one open file. Windows.Data.Pdf and PDFKit do this; an app makes one per
/// document it hands to Core.
/// </summary>
public interface IPageRenderer
{
    /// <summary>The page as displayed, /Rotate and crop box applied, at <paramref name="dpi"/>. Null when the system cannot draw it.</summary>
    PdfRgbaImage? Render(int pageIndex, double dpi);
}
