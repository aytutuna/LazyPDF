namespace LazyPDF.Core.Office;

/// <summary>Makes PDFs from Office files without Office.</summary>
public static class OfficeConverter
{
    /// <summary>Converts a .docx file. <paramref name="fonts"/> is the app's font source, normally an <see cref="IFontSource"/> that falls back to the bundled fonts. <paramref name="images"/> reads pictures that are not JPEG.</summary>
    /// <exception cref="PdfReadException">The file is not a readable Word document, or is over a limit.</exception>
    internal static OfficePdf FromWord(byte[] docx, IFontSource? fonts, IImageCodec? images = null, CancellationToken cancellation = default) =>
        OfficePdfWriter.Create(DocxReader.Read(docx, cancellation), fonts, cancellation, images: images);
}
