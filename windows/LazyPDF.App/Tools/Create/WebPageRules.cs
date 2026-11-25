using System.Text.RegularExpressions;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

/// <summary>Page size and margin in inches, as the web view takes them.</summary>
internal readonly record struct WebPageLayout(double Width, double Height, double Margin);

/// <summary>What a web page file may load and how its paper is set, kept apart from the web view so it can be tested.</summary>
internal static class WebPageRules
{
    /// <summary>The largest page file taken; a bigger one is more likely a crafted file than a document.</summary>
    public const long MostBytes = 20 << 20;

    /// <summary>The most pages a page may make before the work is given up.</summary>
    public const int MostPages = 2000;

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

    private static readonly Regex RemoteStyle = new(
        @"url\(\s*(?:[""']\s*)?(?:https?:)?//|@import\s+(?:url\(\s*)?(?:[""']\s*)?(?:https?:)?//",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly HashSet<string> LoadingTags = ["img", "script", "link", "source", "video", "audio", "iframe", "embed", "object", "input", "image", "use"];
    private static readonly HashSet<string> LoadingAttributes = ["src", "href", "poster", "data", "srcset"];
    private const int MostTagChars = 2000;

    /// <summary>True when the page asks for a picture, style, font or other part from the internet, which the page rules leave out of the PDF. Links to other pages do not count.</summary>
    public static bool NamesRemoteParts(string html) => NamesRemoteTagPart(html) || RemoteStyle.IsMatch(html);

    // Read once from left to right: a tag that loads something is looked at up to its '>' or 2000 characters, and the scan goes on
    // after that, so a file of tag starts costs no more than its length.
    private static bool NamesRemoteTagPart(string b)
    {
        static bool IsWord(char c) => c is (>= '0' and <= '9') or (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or '_';
        static bool IsSpace(char c) => c == ' ' || (c >= '\t' && c <= '\r');
        string Word(int from, out int end)
        {
            end = from;
            while (end < b.Length && IsWord(b[end])) end++;
            return b[from..end].ToLowerInvariant();
        }
        bool RemoteAt(int from)
        {
            int i = from;
            if (i + 1 < b.Length && b[i] == '/' && b[i + 1] == '/') return true;
            foreach (char letter in "http")
            {
                if (i >= b.Length || char.ToLowerInvariant(b[i]) != letter) return false;
                i++;
            }
            if (i < b.Length && char.ToLowerInvariant(b[i]) == 's') i++;
            return i + 2 < b.Length && b[i] == ':' && b[i + 1] == '/' && b[i + 2] == '/';
        }

        int i = 0;
        while (i < b.Length)
        {
            if (b[i] != '<') { i++; continue; }
            string name = Word(i + 1, out int nameEnd);
            if (nameEnd == i + 1 || !LoadingTags.Contains(name)) { i++; continue; }
            int end = nameEnd;
            while (end < b.Length && b[end] != '>' && end - nameEnd < MostTagChars) end++;
            int j = nameEnd;
            while (j < end)
            {
                if (!IsWord(b[j]) || IsWord(b[j - 1])) { j++; continue; }
                string attribute = Word(j, out j);
                if (!LoadingAttributes.Contains(attribute)) continue;
                int k = j;
                while (k < end && IsSpace(b[k])) k++;
                if (k >= b.Length || b[k] != '=') continue;
                k++;
                while (k < end && IsSpace(b[k])) k++;
                if (k < b.Length && (b[k] == '"' || b[k] == '\'')) k++;
                while (k < end && IsSpace(b[k])) k++;
                if (RemoteAt(k)) return true;
            }
            i = end;
        }
        return false;
    }
}

/// <summary>A web page that is over a limit or took too long; the rest of the failures are IO errors.</summary>
public enum WebPageProblem
{
    TooBig,
    TimedOut,
    TooLong,
}

internal sealed class WebPageException(WebPageProblem problem) : Exception($"The web page is refused: {problem}.")
{
    public WebPageProblem Problem { get; } = problem;
}

/// <summary>The WebView2 Runtime is not on this computer.</summary>
internal sealed class WebViewMissingException() : Exception("The WebView2 Runtime is not installed.");
