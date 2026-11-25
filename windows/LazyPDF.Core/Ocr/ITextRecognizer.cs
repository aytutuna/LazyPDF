namespace LazyPDF.Core;

/// <summary>A box in the pixels of the image that was read: origin top-left, y down.</summary>
public readonly record struct OcrBox(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

/// <summary>One recognized word and where it sits in the image.</summary>
/// <param name="Confidence">0 to 1; 1 when the engine does not say.</param>
/// <param name="Angle">
/// How far the line the word is on is turned, in radians, counter-clockwise as seen. <paramref name="Box"/> is then the
/// word's box in the line's own upright frame, its bottom-left corner on the baseline where the word starts. 0 for a straight line.
/// </param>
public sealed record OcrWord(string Text, OcrBox Box, float Confidence = 1f, double Angle = 0);

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
