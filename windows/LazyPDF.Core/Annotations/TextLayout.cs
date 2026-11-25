namespace LazyPDF.Core;

/// <summary>
/// A stretch of one run set in one font. <paramref name="Offset"/> is where it starts in the paragraph's text; with
/// <paramref name="RightToLeft"/> it is a right-to-left run of the line and is drawn as one.
/// </summary>
internal sealed record Piece(TextRun Run, PdfDrawFont Font, string Text, double Width, int Offset = 0, bool RightToLeft = false);

/// <summary>A line of pieces in display order. <paramref name="RightToLeft"/>: the paragraph runs right to left, so the line starts on the right.</summary>
internal sealed record TextLine(List<Piece> Pieces, double Width, double Ascent, double Height, bool RightToLeft = false);

/// <summary>
/// Breaks paragraphs of formatted runs into lines no wider than a box, measuring with the fonts that will draw them.
/// Lines are broken on the logical text; a paragraph with right-to-left characters then gets its bidi levels
/// resolved (the base direction is the first strong character's) and each line cut into directional pieces in display order.
/// </summary>
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
            string whole = string.Concat(paragraph.Select(r => r.Text));
            var bidi = Scripts.NeedsBidi(whole) ? new BidiParagraph(whole) : null;
            var pieces = new List<Piece>();
            double width = 0;
            int runStart = 0;
            foreach (var run in paragraph)
            {
                var font = fontFor(run.Format);
                int tokenStart = runStart;
                foreach (string token in Tokens(run.Text))
                {
                    int offset = tokenStart;
                    tokenStart += token.Length;
                    double bare = font.Width(token.TrimEnd(), run.Format.Size);
                    if (pieces.Count > 0 && width + bare > maxWidth)
                    {
                        Finish(lines, pieces, ref width, bidi);
                        if (lines.Count >= MaxLines) return lines;
                    }
                    if (bare > maxWidth)
                    {
                        foreach (string chunk in Chunks(token.TrimEnd(), font, run.Format.Size, maxWidth))
                        {
                            if (pieces.Count > 0) Finish(lines, pieces, ref width, bidi);
                            pieces.Add(new Piece(run, font, chunk, font.Width(chunk, run.Format.Size), offset));
                            offset += chunk.Length;
                            width = pieces[^1].Width;
                        }
                        continue;
                    }
                    double full = font.Width(token, run.Format.Size);
                    pieces.Add(new Piece(run, font, token, full, offset));
                    width += full;
                }
                runStart += run.Text.Length;
            }
            Finish(lines, pieces, ref width, bidi);
        }
        return lines;
    }

    private static void Finish(List<TextLine> lines, List<Piece> pieces, ref double width, BidiParagraph? bidi)
    {
        if (pieces.Count > 0 && pieces[^1].Text.EndsWith(' '))
        {
            var last = pieces[^1];
            string trimmed = last.Text.TrimEnd();
            pieces[^1] = last with { Text = trimmed, Width = last.Font.Width(trimmed, last.Run.Format.Size) };
        }
        var shown = bidi is null || pieces.Count == 0 ? [.. pieces] : DisplayOrder(pieces, bidi);
        double total = shown.Sum(p => p.Width);
        double ascent = shown.Count > 0 ? shown.Max(p => p.Font.Ascent * p.Run.Format.Size) : 0;
        double height = shown.Count > 0 ? shown.Max(p => p.Font.LineHeight(p.Run.Format.Size)) : 0;
        lines.Add(new TextLine(shown, total, ascent, height, bidi?.Level == 1));
        pieces.Clear();
        width = 0;
    }

    // L1 and L2 on a line of pieces: cut each piece where the level changes, then turn the runs around from the highest level down.
    private static List<Piece> DisplayOrder(List<Piece> pieces, BidiParagraph bidi)
    {
        int first = pieces[0].Offset, last = pieces[^1].Offset + pieces[^1].Text.Length;
        var levels = bidi.LineLevels(first, last);
        var runs = new List<(Piece Piece, int Level)>();
        foreach (var piece in pieces.Where(p => p.Text.Length > 0))
        {
            // A character the algorithm removed (level -1) takes the level of the one before it.
            int LevelAt(int i, int before) => levels[piece.Offset - first + i] is var l and >= 0 ? l : before;
            int from = 0, current = LevelAt(0, bidi.Level);
            for (int i = 1; i <= piece.Text.Length; i++)
            {
                int next = i < piece.Text.Length ? LevelAt(i, current) : -1;
                if (next == current) continue;
                string text = piece.Text[from..i];
                bool rtl = (current & 1) == 1;
                runs.Add((piece with { Text = text, Offset = piece.Offset + from, RightToLeft = rtl, Width = piece.Font.RunWidth(text, rtl, piece.Run.Format.Size) }, current));
                from = i;
                current = next;
            }
        }
        if (runs.Count == 0) return [];
        int highest = runs.Max(r => r.Level);
        int lowestOdd = runs.Where(r => (r.Level & 1) == 1).Select(r => r.Level).DefaultIfEmpty(int.MaxValue).Min();
        for (int level = highest; level >= lowestOdd; level--)
        {
            for (int i = 0; i < runs.Count; i++)
            {
                if (runs[i].Level < level) continue;
                int j = i;
                while (j + 1 < runs.Count && runs[j + 1].Level >= level) j++;
                runs.Reverse(i, j - i + 1);
                i = j;
            }
        }
        return [.. runs.Select(r => r.Piece)];
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
