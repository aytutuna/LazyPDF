using System.Globalization;

namespace LazyPDF.Core;

/// <summary>Texts the OCR action raises to the user. Loc.T takes them over when it exists.</summary>
public static class OcrStatusText
{
    public const string Label = "Make searchable";
    public const string Nothing = "No pages need text recognition.";

    public static string Status(int page, int total) =>
        string.Create(CultureInfo.InvariantCulture, $"Reading page {page} of {total}");

    public static string StatusFull(int page, int total) =>
        string.Create(CultureInfo.InvariantCulture, $"Recognizing the text on page {page} of {total}.");
}
