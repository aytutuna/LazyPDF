using System.IO;

namespace LazyPDF.App.Services;

internal enum OfficeApp { Word, Excel, PowerPoint }

/// <summary>What a file is by its name, for the open dialog and for turning pictures and text into a PDF.</summary>
internal static class FileKinds
{
    private static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];
    private static readonly string[] TextExtensions = [".txt"];
    private static readonly string[] OldOfficeExtensions = [".doc", ".xls", ".ppt"];

    /// <summary>The Office files that can be made into a PDF, and the program each is made by; a new kind is one more entry.</summary>
    private static readonly Dictionary<string, OfficeApp> OfficeExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        [".docx"] = OfficeApp.Word,
        [".xlsx"] = OfficeApp.Excel,
        [".pptx"] = OfficeApp.PowerPoint,
    };

    public static bool IsPicture(string path) => PictureExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static bool IsText(string path) => TextExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static OfficeApp? OfficeAppOf(string path) => OfficeExtensions.TryGetValue(Path.GetExtension(path), out var app) ? app : null;

    /// <summary>The binary formats before Office 2007, which cannot be read and must be saved in the new ones first.</summary>
    public static bool IsOldOffice(string path) => OldOfficeExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>The filter of the dialog that picks a file for the Create tool; it lists the old formats too, so choosing one shows the "save it as" message.</summary>
    public static string OfficeFilter(string label) => $"{label}|{Patterns(OfficeExtensions.Keys.Concat(OldOfficeExtensions).ToArray())}";

    /// <summary>The filter of the open dialog.</summary>
    public static string OpenFilter(string pdf, string pictures, string text, string all) =>
        $"{all}|*.pdf;*.txt;{Patterns(PictureExtensions)}|{pdf}|*.pdf|{pictures}|{Patterns(PictureExtensions)}|{text}|*.txt";

    private static string Patterns(string[] extensions) => string.Join(';', extensions.Select(e => "*" + e));
}
