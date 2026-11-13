using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

/// <summary>Page size and margin in inches, as the web view takes them.</summary>
internal readonly record struct WebPageLayout(double Width, double Height, double Margin);

/// <summary>What a web page file may load and how its paper is set, kept apart from the web view so it can be tested.</summary>
internal static class WebPageRules
{
    public static readonly string[] Extensions = [".html", ".htm"];

    public static bool IsWebPage(string path) => Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>The page's folder is served from this https name, so the page cannot reach file: or network shares itself.</summary>
    public const string Host = "page.lazypdf.invalid";

    /// <summary>Address of a page file under <see cref="Host"/>.</summary>
    public static string PageAddress(string file) => $"https://{Host}/{Uri.EscapeDataString(Path.GetFileName(file))}";

    /// <summary>The page's own folder, reached through <see cref="Host"/>, or data held in the address itself. Anything that would leave the machine, or leave the folder, is refused.</summary>
    public static bool IsAllowed(string address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme is "data" or "about") return true;
        return uri.Scheme == Uri.UriSchemeHttps && uri.Port == 443 && string.IsNullOrEmpty(uri.UserInfo)
            && string.Equals(uri.Host, Host, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The page is laid out as a printer would; Auto is upright, since a web page is written for width.</summary>
    public static WebPageLayout Layout(PdfPageSetup setup)
    {
        var (points, tall) = ExportPdf.Paper(setup, landscape: false);
        double width = points / 72, height = tall / 72;
        double margin = setup.Margin / 72;
        if (margin < 0 || margin * 2 >= Math.Min(width, height)) throw new ArgumentException("The margin leaves no room on the page.");
        return new(width, height, margin);
    }
}

/// <summary>The WebView2 Runtime is not on this computer.</summary>
internal sealed class WebViewMissingException() : Exception("The WebView2 Runtime is not installed.");
