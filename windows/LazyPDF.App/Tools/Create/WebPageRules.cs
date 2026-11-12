using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

/// <summary>Page size and margin in inches, as the web view takes them.</summary>
internal readonly record struct WebPageLayout(double Width, double Height, double Margin);

/// <summary>What a web page file may load and how its paper is set, kept apart from the web view so it can be tested.</summary>
internal static class WebPageRules
{
    public static readonly string[] Extensions = [".html", ".htm"];

    public static bool IsWebPage(string path) => Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>A file under the page's own folder, or data held in the address itself. Anything that would leave the machine, or leave the folder, is refused.</summary>
    public static bool IsAllowed(string address, string folder)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme is "data" or "about") return true;
        if (!uri.IsFile) return false;
        try
        {
            string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)) + Path.DirectorySeparatorChar;
            return Path.GetFullPath(uri.LocalPath).StartsWith(root, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    /// <summary>The page is laid out as a printer would; Auto is upright, since a web page is written for width.</summary>
    public static WebPageLayout Layout(PdfPageSetup setup)
    {
        var (width, height) = setup.Paper == PdfPaper.Letter ? (8.5, 11.0) : (210 / 25.4, 297 / 25.4);
        if (setup.Orientation == PdfOrientation.Landscape) (width, height) = (height, width);
        double margin = setup.Margin / 72;
        if (margin < 0 || margin * 2 >= Math.Min(width, height)) throw new ArgumentException("The margin leaves no room on the page.");
        return new(width, height, margin);
    }
}

/// <summary>The WebView2 Runtime is not on this computer.</summary>
internal sealed class WebViewMissingException() : Exception("The WebView2 Runtime is not installed.");
