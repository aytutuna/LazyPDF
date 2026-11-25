using System.IO;

namespace LazyPDF.App.Services;

/// <summary>
/// Where the app keeps files. Settings and the other data sit in the user's AppData, which a packaged app reaches
/// as usual while Windows keeps the writes in the package's store. A file another program has to read goes in the
/// temp folder instead: from AppData the package's own copy would be the only one.
/// </summary>
internal static class AppFolders
{
    private static string LocalData => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lazy PDF");

    public static string Recovery => Path.Combine(LocalData, "Recovery");

    public static string Thumbnails => Path.Combine(LocalData, "Thumbnails");

    public static string WebView => Path.Combine(LocalData, "WebView");

    /// <summary>The copies of open documents handed to Lazy Print.</summary>
    public static string PrintCopies => Path.Combine(Path.GetTempPath(), "Lazy PDF", "Print");

    /// <summary>Attachments opened in the program that handles their type.</summary>
    public static string OpenedAttachments => Path.Combine(Path.GetTempPath(), "Lazy PDF", "Attachments");
}
