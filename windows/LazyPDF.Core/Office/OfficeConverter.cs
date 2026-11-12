namespace LazyPDF.Core.Office;

/// <summary>Makes PDFs from Office files without Office.</summary>
public static class OfficeConverter
{
    /// <summary>Converts a .docx file. <paramref name="fonts"/> is the app's font source, normally an <see cref="OfficeFontSource"/> that falls back to the bundled fonts. <paramref name="images"/> reads pictures that are not JPEG.</summary>
    /// <exception cref="PdfReadException">The file is not a readable Word document, or is over a limit.</exception>
    public static OfficePdf FromWord(byte[] docx, IFontSource? fonts, IImageCodec? images = null, CancellationToken cancellation = default) =>
        OfficePdfWriter.Create(DocxReader.Read(docx, cancellation), fonts, cancellation, images: images);

    /// <summary>Converts an .xlsx file, one or more pages per visible sheet as Excel would print it. <paramref name="fileName"/> fills the file name field of headers and footers.</summary>
    /// <exception cref="PdfReadException">The file is not a readable Excel workbook, is over a limit, or has nothing to print.</exception>
    public static OfficePdf FromExcel(byte[] xlsx, IFontSource? fonts, string fileName = "", CancellationToken cancellation = default)
    {
        var book = XlsxReader.Read(xlsx, cancellation: cancellation);
        return OfficePdfWriter.Create(XlsxLayout.Run(book, new LayoutFonts(fonts), DateTime.Now, fileName, cancellation), fonts, cancellation);
    }

    /// <summary>Converts a .pptx file, one page per slide that is not hidden. <paramref name="images"/> reads pictures that are not JPEG.</summary>
    /// <exception cref="PdfReadException">The file is not a readable PowerPoint presentation, is over a limit, or has no slide to show.</exception>
    public static OfficePdf FromPowerPoint(byte[] pptx, IFontSource? fonts, IImageCodec? images = null, CancellationToken cancellation = default)
    {
        var presentation = PptxReader.Read(pptx, cancellation: cancellation);
        return OfficePdfWriter.Create(PptxLayout.Run(presentation, new LayoutFonts(fonts), cancellation), fonts, cancellation, images: images);
    }
}
