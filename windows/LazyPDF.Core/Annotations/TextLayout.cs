namespace LazyPDF.Core;

internal sealed record Piece(TextRun Run, PdfDrawFont Font, string Text, double Width);

internal sealed record TextLine(List<Piece> Pieces, double Width, double Ascent, double Height);

/// <summary>Breaks paragraphs of formatted runs into lines no wider than a box, measuring with the fonts that will draw them.</summary>
internal static class TextLayout
{
    private const int MaxLines = 5_000;

    public static List<TextLine> Layout(List<List<TextRun>> paragraphs, double maxWidth, TextFormat blank, Func<TextFormat, PdfDrawFont> fontFor)
    {
        var lines = new List<TextLine>();
        foreach (var paragraph in paragraphs)
        {
            if (lines.Count >= MaxLines) break;
            if (paragraph.Count == 0)
            {
                var font = fontFor(blank);
                lines.Add(new TextLine([], 0, font.Ascent * blank.Size, font.LineHeight(blank.Size)));
                continue;
            }
            var pieces = new List<Piece>();
            double width = 0;
            foreach (var run in paragraph)
            {
                var font = fontFor(run.Format);
                foreach (string token in Tokens(run.Text))
                {
                    double bare = font.Width(token.TrimEnd(), run.Format.Size);
                    if (pieces.Count > 0 && width + bare > maxWidth)
                    {
                        Finish(lines, pieces, ref width);
                        if (lines.Count >= MaxLines) return lines;
                    }
                    if (bare > maxWidth)
                    {
                        foreach (string chunk in Chunks(token.TrimEnd(), font, run.Format.Size, maxWidth))
                        {
                            if (pieces.Count > 0) Finish(lines, pieces, ref width);
                            pieces.Add(new Piece(run, font, chunk, font.Width(chunk, run.Format.Size)));
                            width = pieces[^1].Width;
                        }
                        continue;
                    }
                    double full = font.Width(token, run.Format.Size);
                    pieces.Add(new Piece(run, font, token, full));
                    width += full;
                }
            }
            Finish(lines, pieces, ref width);
        }
        return lines;
    }

    private static void Finish(List<TextLine> lines, List<Piece> pieces, ref double width)
    {
        if (pieces.Count > 0 && pieces[^1].Text.EndsWith(' '))
        {
            var last = pieces[^1];
            string trimmed = last.Text.TrimEnd();
            pieces[^1] = last with { Text = trimmed, Width = last.Font.Width(trimmed, last.Run.Format.Size) };
        }
        double total = pieces.Sum(p => p.Width);
        double ascent = pieces.Count > 0 ? pieces.Max(p => p.Font.Ascent * p.Run.Format.Size) : 0;
        double height = pieces.Count > 0 ? pieces.Max(p => p.Font.LineHeight(p.Run.Format.Size)) : 0;
        lines.Add(new TextLine([.. pieces], total, ascent, height));
        pieces.Clear();
        width = 0;
    }

    // Each word with the spaces after it, so a break falls between words.
    private static IEnumerable<string> Tokens(string text)
    {
        int start = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] != ' ' || (i + 1 < text.Length && text[i + 1] == ' ')) continue;
            yield return text[start..(i + 1)];
            start = i + 1;
        }
        if (start < text.Length) yield return text[start..];
    }

    private static IEnumerable<string> Chunks(string word, PdfDrawFont font, double size, double maxWidth)
    {
        var chunk = new System.Text.StringBuilder();
        foreach (var rune in word.EnumerateRunes())
        {
            if (chunk.Length > 0 && font.Width(chunk + rune.ToString(), size) > maxWidth)
            {
                yield return chunk.ToString();
                chunk.Clear();
            }
            chunk.Append(rune.ToString());
        }
        if (chunk.Length > 0) yield return chunk.ToString();
    }
}
