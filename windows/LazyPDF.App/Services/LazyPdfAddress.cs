using System.IO;

namespace LazyPDF.App.Services;

/// <summary>
/// The addresses that start Lazy PDF: <c>lazypdf:</c> alone brings the window forward and
/// <c>lazypdf://open?file=C%3A%5Cdocs%5Ca.pdf</c> opens that file (repeat <c>file</c> for more).
/// </summary>
public static class LazyPdfAddress
{
    public const string Scheme = "lazypdf";

    public static bool IsAddress(string text) => text.TrimStart().StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);

    /// <summary>The full local paths an address names; none for one that names no file. Network paths are skipped: opening one would make Windows connect and send the user's credentials.</summary>
    public static IReadOnlyList<string> Parse(string address)
    {
        int query = address.IndexOf('?');
        if (query < 0) return [];
        var files = new List<string>();
        foreach (string pair in address[(query + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int equals = pair.IndexOf('=');
            if (equals < 0 || pair[..equals] != "file") continue;
            string path = Uri.UnescapeDataString(pair[(equals + 1)..].Replace('+', ' '));
            if (Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\") && !path.StartsWith("//")) files.Add(path);
        }
        return files;
    }
}
