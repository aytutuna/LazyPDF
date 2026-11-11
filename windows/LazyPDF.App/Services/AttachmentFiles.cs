using System.IO;

namespace LazyPDF.App.Services;

/// <summary>Names for the copies made of files carried inside a PDF, and which of them could start a program.</summary>
internal static class AttachmentFiles
{
    private static readonly string[] Programs =
    [
        ".exe", ".com", ".bat", ".cmd", ".msi", ".msp", ".ps1", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".scr",
        ".lnk", ".url", ".hta", ".jar", ".reg", ".dll", ".cpl", ".msc", ".pif", ".chm", ".application", ".appref-ms",
        ".jnlp", ".diagcab", ".settingcontent-ms",
        ".docm", ".dotm", ".xlsm", ".xltm", ".xlam", ".xll", ".pptm", ".potm", ".ppam", ".ppsm", ".sldm", ".one",
        ".iso", ".img", ".vhd", ".vhdx",
        ".py", ".pyw", ".ws", ".sct", ".wsc", ".psm1", ".psd1", ".ps1xml", ".vb",
        ".library-ms", ".search-ms", ".scf", ".inf", ".theme", ".themepack", ".msix", ".msixbundle", ".appx", ".appxbundle",
        ".appinstaller", ".msu", ".cab",
    ];

    /// <summary>The file name only, with characters Windows refuses replaced. Windows drops trailing dots and spaces when it writes a file, so they are dropped here and the name checked is the name written.</summary>
    public static string SafeName(string name)
    {
        char[] invalid = Path.GetInvalidFileNameChars();
        string clean = string.Concat(Path.GetFileName(name).Select(c => Array.IndexOf(invalid, c) >= 0 ? '_' : c));
        return clean.TrimEnd('.', ' ');
    }

    public static bool CouldRun(string safeName) =>
        Programs.Contains(Path.GetExtension(safeName), StringComparer.OrdinalIgnoreCase);
}
