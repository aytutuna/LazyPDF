using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>A line of a <see cref="TextPage"/> with the numbers the tagger judges it by, in display points.</summary>
internal sealed class TagLine
{
    private TagLine(TextRange range, DisplayRect rect, double size, bool bold, string text, TextBreak before, bool vertical)
    {
        (Range, Rect, Size, Bold, Text, Before, IsVertical) = (range, rect, size, bold, text, before, vertical);
    }

    public TagLine(TextPage page, PageLine source, PageGeometry geometry)
    {
        Range = source.Range;
        Rect = geometry.ToDisplay(source.Bounds);
        Text = source.Text.Trim();
        Before = source.Before;
        IsVertical = source.IsVertical;
        var sizes = new Dictionary<double, int>();
        int bold = 0, glyphs = 0;
        for (int i = source.Range.Start; i < source.Range.End; i++)
        {
            var c = page.Chars[i];
            if (c.IsSpace || c.Text.Length == 0) continue;
            glyphs++;
            if (c.Font is { } font && (font.IsBold || font.Name.Contains("Black", StringComparison.OrdinalIgnoreCase))) bold++;
            double size = Math.Round(c.Size * 2) / 2;
            sizes[size] = sizes.GetValueOrDefault(size) + 1;
        }
        Size = sizes.Count == 0 ? 0 : sizes.MaxBy(s => s.Value).Key;
        Bold = glyphs > 0 && bold * 2 > glyphs;
    }

    public TextRange Range { get; }
    public DisplayRect Rect { get; }
    public double Size { get; }
    public bool Bold { get; }
    public string Text { get; }
    public TextBreak Before { get; }
    public bool IsVertical { get; }

    /// <summary>A lone list marker and the text after it, which the layout set apart as a table cell, as one line.</summary>
    public static TagLine Join(TagLine marker, TagLine body)
    {
        double x = Math.Min(marker.Rect.X, body.Rect.X), y = Math.Min(marker.Rect.Y, body.Rect.Y);
        var rect = new DisplayRect(x, y, Math.Max(marker.Rect.X + marker.Rect.Width, body.Rect.X + body.Rect.Width) - x,
            Math.Max(marker.Rect.Y + marker.Rect.Height, body.Rect.Y + body.Rect.Height) - y);
        return new TagLine(new TextRange(marker.Range.Start, body.Range.End), rect, body.Size, body.Bold, marker.Text + " " + body.Text, marker.Before, body.IsVertical);
    }
}

internal readonly record struct ListMarker(bool Numbered, int Length);

internal static class TagText
{
    private const string Bullets = "•◦▪▫●○■□◆◇‣⁃∙·►▸➢➤✓✔➔";

    private static readonly Regex NumberedPattern = new(@"^(\(?(\d{1,3}|[A-Za-z]|[ivxIVX]{1,5})[.)])(\s|$)", RegexOptions.CultureInvariant);

    private static readonly Regex PageNumberPattern = new(@"^(page\s*)?(\d{1,4}|[ivxlcdm]{1,6})(\s*(of|/)\s*\d{1,4})?$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    /// <summary>The line's text with digits folded, so that "Page 3" and "Page 4" are one thing; null for text with no letter or digit.</summary>
    public static string? Signature(string text)
    {
        var folded = new System.Text.StringBuilder();
        bool any = false;
        foreach (char c in text.Trim().ToLowerInvariant())
        {
            if (char.IsDigit(c))
            {
                if (folded.Length == 0 || folded[^1] != '#') folded.Append('#');
                any = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (folded.Length > 0 && folded[^1] != ' ') folded.Append(' ');
            }
            else
            {
                folded.Append(c);
                any |= char.IsLetter(c);
            }
        }
        return any ? folded.ToString().Trim() : null;
    }

    public static bool IsPageNumber(string text) => PageNumberPattern.IsMatch(text.Trim().Trim('-', '–', '—', ' '));

    /// <summary>"T" or "B" when the line is in the top or bottom tenth of the page, else null.</summary>
    public static string? Band(TagLine line, double pageHeight)
    {
        double middle = line.Rect.Y + line.Rect.Height / 2;
        return middle < pageHeight * 0.1 ? "T" : middle > pageHeight * 0.9 ? "B" : null;
    }

    public static bool IsLoneMarker(string text) => text.Length <= 5 && MarkerOf(text + " x") is { } marker && marker.Length == text.Length;

    public static ListMarker? MarkerOf(string text)
    {
        if (text.Length < 2) return null;
        char first = text[0];
        if (Bullets.Contains(first) || first is >= '' and <= '') return new ListMarker(false, 1);
        if (first is '-' or '–' or '—' or '*' && text[1] == ' ') return new ListMarker(false, 1);
        var m = NumberedPattern.Match(text);
        return m.Success ? new ListMarker(true, m.Groups[1].Length) : null;
    }
}
