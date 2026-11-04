using System.Text;

namespace LazyPDF.Core;

/// <summary>Plain text of pages.</summary>
public static class TextExport
{
    /// <summary>The text of one page; see <see cref="TextPage.GetText"/> for what <paramref name="joinHyphens"/> does.</summary>
    public static string Page(TextPage page, bool joinHyphens = false) =>
        page.GetText(new TextRange(0, page.Chars.Count), joinHyphens);

    /// <summary>The pages <paramref name="first"/> to <paramref name="last"/> (0-based, inclusive), each followed by a form feed as <c>pdftotext</c> writes them.</summary>
    public static string Range(TextCache cache, int first, int last, bool joinHyphens = false, CancellationToken cancel = default)
    {
        var sb = new StringBuilder();
        for (int p = Math.Max(first, 0); p <= Math.Min(last, cache.PageCount - 1); p++)
        {
            cancel.ThrowIfCancellationRequested();
            sb.Append(Page(cache.Get(p), joinHyphens)).Append('\f');
        }
        return sb.ToString();
    }
}
