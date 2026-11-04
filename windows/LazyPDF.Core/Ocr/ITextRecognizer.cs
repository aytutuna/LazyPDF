namespace LazyPDF.Core;

/// <summary>A box in the pixels of the image that was read: origin top-left, y down.</summary>
public readonly record struct OcrBox(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

/// <summary>One recognized word and where it sits in the image.</summary>
/// <param name="Confidence">0 to 1; 1 when the engine does not say.</param>
public sealed record OcrWord(string Text, OcrBox Box, float Confidence = 1f);

/// <summary>
/// Text recognition over a picture of a page. Windows.Media.Ocr and Vision are behind it; an app
/// passes an implementation in.
/// </summary>
public interface ITextRecognizer
{
    /// <param name="language">A BCP 47 tag such as "en-US" or "tr".</param>
    /// <returns>The words found, boxes in the pixels of <paramref name="image"/>; empty when there is no text.</returns>
    Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default);
}
