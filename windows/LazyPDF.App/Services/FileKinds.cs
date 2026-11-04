using System.IO;

namespace LazyPDF.App.Services;

/// <summary>What a file is by its name, for the open dialog and for turning pictures and text into a PDF.</summary>
internal static class FileKinds
{
    private static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];
    private static readonly string[] TextExtensions = [".txt"];

    public static bool IsPicture(string path) => PictureExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static bool IsText(string path) => TextExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>The filter of the open dialog.</summary>
    public static string OpenFilter(string pdf, string pictures, string text, string all) =>
        $"{all}|*.pdf;*.txt;{Patterns(PictureExtensions)}|{pdf}|*.pdf|{pictures}|{Patterns(PictureExtensions)}|{text}|*.txt";

    private static string Patterns(string[] extensions) => string.Join(';', extensions.Select(e => "*" + e));
}
