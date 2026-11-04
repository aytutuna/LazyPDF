using System.Globalization;

namespace LazyPDF.Core;

/// <summary>The few words the export writes into its files and that a person may read.</summary>
public static class ExportText
{
    public static string Page(int number) => string.Create(CultureInfo.InvariantCulture, $"Page {number}");
    public static string Image(int number) => string.Create(CultureInfo.InvariantCulture, $"Image {number}");
    public static string Table(int number, int page) => string.Create(CultureInfo.InvariantCulture, $"Table {number} (p{page})");
    public static string Slide(int number) => string.Create(CultureInfo.InvariantCulture, $"Slide {number}");

    public const string NoUsablePicture = "None of the pictures could be read.";
    public const string TooLarge = "The document is too large to export.";
    public const string NoFont = "No font file can draw this text.";
}
