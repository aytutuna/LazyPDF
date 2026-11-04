using System.Text.RegularExpressions;

namespace LazyPDF.App.Services;

// From Lazy Print's StatusLine.cs, without the print job notes: the status line shows at most six words
// of the status sentence, facts only, and the whole sentence stays the line's accessible name.

/// <summary>The status line's visible text: at most <see cref="MaxWords"/> words, facts only.</summary>
public static class StatusLine
{
    public const int MaxWords = 6;

    private static readonly Regex WordToken = new(@"[\p{L}\p{N}]", RegexOptions.Compiled);

    /// <summary>Words as the text spec counts them: whitespace-separated tokens with a letter or digit.</summary>
    public static int Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(t => WordToken.IsMatch(t));

    /// <summary>The first sentence of <paramref name="message"/>, cut at a dash, colon or comma when it is longer than six words.</summary>
    public static string Short(string message)
    {
        string text = message.Trim();
        if (text.Length == 0) return "";
        string first = FirstSentence(text);
        if (Words(first) <= MaxWords) return first;
        foreach (string mark in new[] { " — ", ": ", ", " })
        {
            int at = first.IndexOf(mark, StringComparison.Ordinal);
            if (at > 0 && Words(first[..at]) <= MaxWords) return first[..at];
        }
        var kept = new List<string>();
        int words = 0;
        foreach (var token in first.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (WordToken.IsMatch(token) && ++words > MaxWords) break;
            kept.Add(token);
        }
        return string.Join(' ', kept).TrimEnd(',', ':', ';', '.', ' ') + "…";
    }

    /// <summary>The first sentence without its full stop ("…" is kept: it says work is under way).</summary>
    private static string FirstSentence(string text)
    {
        for (int i = 0; i < text.Length - 2; i++)
        {
            if (text[i] is '.' or '!' or '?' && text[i + 1] == ' ' && (char.IsUpper(text[i + 2]) || char.IsDigit(text[i + 2])))
            {
                return text[..i];
            }
        }
        return text.EndsWith('.') && !text.EndsWith("…", StringComparison.Ordinal) ? text[..^1] : text;
    }
}
