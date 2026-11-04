using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class TextInvariants
{
    public static string? Check(TextPage page)
    {
        int expectedLine = 0, next = 0;
        foreach (var line in page.Lines)
        {
            if (line.Index != expectedLine++ || line.Range.Start != next || line.Range.End <= line.Range.Start) return "line ranges do not tile the characters";
            next = line.Range.End;
        }
        if (next != page.Chars.Count) return "lines do not cover all characters";
        for (int i = 0; i < page.Chars.Count; i++)
        {
            var c = page.Chars[i];
            var q = c.Quad;
            if (c.Index != i || !double.IsFinite(q.X0 + q.Y0 + q.X1 + q.Y1 + q.X2 + q.Y2 + q.X3 + q.Y3)) return "character with a bad index or box";
            if (c.Line < 0 || c.Line >= page.Lines.Count || !(page.Lines[c.Line].Range.Start <= i && i < page.Lines[c.Line].Range.End)) return "character outside its line";
        }
        if (page.Words.Any(w => w.Range.IsEmpty || page.Chars[w.Range.Start].Word != w.Index)) return "bad word";
        if (page.Blocks.Sum(b => b.Lines.Count) != page.Lines.Count) return "blocks do not cover all lines";
        _ = page.Text;
        _ = TextSelection.Of(page, new TextRange(0, page.Chars.Count)).Quads();
        return null;
    }
}
