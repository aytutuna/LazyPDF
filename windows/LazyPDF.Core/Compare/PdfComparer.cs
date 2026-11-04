namespace LazyPDF.Core;

/// <summary>
/// Compares two PDF files by what they say: pages are paired by the similarity of their text, then the
/// words, fonts, pictures and annotations of each pair are compared, and the metadata, bookmarks,
/// attachments and form values of the files. Drawings made of paths are not compared; use
/// <see cref="PixelComparer"/> for those. A text that has no Unicode mapping in its font cannot be compared.
/// </summary>
public static class PdfComparer
{
    /// <exception cref="OperationCanceledException"/>
    public static ComparisonResult Compare(PdfDocument before, PdfDocument after, CompareOptions? options = null, CancellationToken cancellation = default) =>
        new Comparison(before, after, options ?? new CompareOptions(), cancellation).Run();
}
