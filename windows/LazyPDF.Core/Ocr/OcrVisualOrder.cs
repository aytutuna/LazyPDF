using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// A word with Hebrew or Arabic letters is written to the page in the order it shows, left to
/// right, as every other producer does: the text extraction in Text/ puts it back in logical order.
/// Applying <see cref="Flip"/> twice gives the word back.
/// </summary>
internal static class OcrVisualOrder
{
    public static string Flip(string text)
    {
        var runes = text.EnumerateRunes().ToList();
        var classes = runes.Select(r => TextBidi.ClassOf(r.ToString())).ToList();
        if (!classes.Contains(BidiClass.R)) return text;
        runes.Reverse();
        classes.Reverse();

        // Letters and numbers that read left to right keep their own order inside the reversed word.
        int n = runes.Count;
        for (int i = 0; i < n;)
        {
            if (!InRun(runes, classes, i))
            {
                runes[i] = Mirror(runes[i]);
                i++;
                continue;
            }
            int j = i;
            while (j < n && InRun(runes, classes, j)) j++;
            runes.Reverse(i, j - i);
            i = j;
        }
        var sb = new StringBuilder(text.Length);
        foreach (var rune in runes) sb.Append(rune);
        return sb.ToString();
    }

    private static bool InRun(List<Rune> runes, List<BidiClass> classes, int i)
    {
        if (classes[i] is BidiClass.L or BidiClass.EN or BidiClass.AN) return true;
        // 3.14 and 1,000 stay whole.
        return i > 0 && i + 1 < runes.Count && runes[i].Value is '.' or ',' or ':' or '/' or '+' or '-'
               && classes[i - 1] is BidiClass.EN or BidiClass.AN && classes[i + 1] is BidiClass.EN or BidiClass.AN;
    }

    private static Rune Mirror(Rune rune) => rune.Value switch
    {
        '(' => new Rune(')'), ')' => new Rune('('), '[' => new Rune(']'), ']' => new Rune('['),
        '{' => new Rune('}'), '}' => new Rune('{'), '<' => new Rune('>'), '>' => new Rune('<'),
        '«' => new Rune('»'), '»' => new Rune('«'),
        _ => rune,
    };
}
