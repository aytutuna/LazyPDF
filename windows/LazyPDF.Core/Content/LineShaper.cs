using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// A glyph of a line with the stretch [<paramref name="Start"/>, <paramref name="End"/>) of the line's text it stands for.
/// <paramref name="Mirrored"/>: the glyph is the mirror image of the one the character has, as for a bracket in right-to-left text.
/// </summary>
internal readonly record struct LineGlyph(ShapedGlyph Shaped, int Start, int End, bool Mirrored);

/// <summary>
/// One line of text ready to draw: <see cref="Glyphs"/> in display order, left to right. <see cref="Text"/> is the logical
/// text without control characters; <see cref="Width"/> is in 1/1000 em.
/// </summary>
/// <param name="NeedsActualText">The glyphs do not map one to one to the characters (ligatures, mirrored brackets), so copying
/// them would not give <see cref="Text"/>; the writer wraps the line in marked content with /ActualText.</param>
internal sealed record ShapedLine(string Text, IReadOnlyList<LineGlyph> Glyphs, double Width, bool NeedsActualText, bool RightToLeft)
{
    /// <summary>The text a reader gets back: <see cref="Text"/> without direction marks and joiners.</summary>
    public string ActualText => string.Concat(Text.EnumerateRunes().Where(r => !CmapShaper.IsInvisible(r.Value)).Select(r => r.ToString()));
}

/// <summary>
/// Resolves the bidi levels of a line (UAX 9), cuts it into directional runs, shapes each run and puts the runs in display order.
/// Lines are broken on logical text before this, so a line is one paragraph or the part of one.
/// </summary>
internal sealed class LineShaper(FontFile file, IShaper shaper, TrueTypeFont measure, string? language)
{
    private const int CacheLimit = 2048;
    private readonly Dictionary<(string, int), ShapedLine> _cache = [];

    /// <param name="baseLevel">0, 1 or <see cref="BidiParagraph.Auto"/> for the first strong character.</param>
    public ShapedLine Shape(string text, int baseLevel = BidiParagraph.Auto)
    {
        if (_cache.TryGetValue((text, baseLevel), out var known)) return known;
        if (_cache.Count >= CacheLimit) _cache.Clear();
        return _cache[(text, baseLevel)] = Build(text, baseLevel);
    }

    private ShapedLine Build(string text, int baseLevel)
    {
        string clean = string.Concat(text.Where(c => c >= 0x20 && c != 0x85 && c != 0x2028 && c != 0x2029));
        var glyphs = new List<LineGlyph>();
        bool mirrored = false, rtl = baseLevel == 1;
        if (clean.Length > 0 && (baseLevel == 1 || Scripts.NeedsBidi(clean)))
        {
            var paragraph = new BidiParagraph(clean, baseLevel);
            rtl = paragraph.Level == 1;
            var runs = Runs(paragraph.LineLevels(0, clean.Length));
            Reorder(runs);
            foreach (var (start, end, level) in runs) mirrored |= AddRun(glyphs, clean, start, end, level);
        }
        else if (clean.Length > 0) AddRun(glyphs, clean, 0, clean.Length, 0);

        int expected = clean.EnumerateRunes().Count(r => !CmapShaper.IsInvisible(r.Value));
        bool actual = mirrored || glyphs.Count != expected || glyphs.Any(g => !IsOneRune(clean, g));
        return new ShapedLine(clean, glyphs, glyphs.Sum(g => g.Shaped.Advance), actual, rtl);
    }

    private static bool IsOneRune(string text, LineGlyph g) =>
        Rune.TryGetRuneAt(text, g.Start, out var rune) && g.End - g.Start == rune.Utf16SequenceLength;

    private bool AddRun(List<LineGlyph> glyphs, string line, int start, int end, int level)
    {
        bool rtl = (level & 1) == 1;
        string run = line[start..end];
        string original = run;
        bool mirrored = false;
        if (rtl) run = Mirror(run, ref mirrored);
        var shaped = shaper.Shape(run, file, rtl, language) ?? CmapShaper.Shape(measure, run, rtl);

        // A glyph stands for the text from its cluster to the next cluster start, whichever way the run is drawn.
        var starts = shaped.Select(g => Math.Clamp(g.Cluster, 0, run.Length)).Distinct().Order().ToList();
        foreach (var g in shaped)
        {
            int from = Math.Clamp(g.Cluster, 0, run.Length);
            int next = starts.IndexOf(from) + 1;
            glyphs.Add(new LineGlyph(g, start + from, start + (next < starts.Count ? starts[next] : run.Length), mirrored && from < run.Length && run[from] != original[from]));
        }
        return mirrored;
    }

    private static string Mirror(string run, ref bool changed)
    {
        var sb = new StringBuilder(run.Length);
        foreach (var rune in run.EnumerateRunes())
        {
            int mirror = BidiData.Mirror(rune.Value);
            changed |= mirror != rune.Value;
            sb.Append(char.ConvertFromUtf32(mirror));
        }
        return sb.ToString();
    }

    // Runs of equal level; a character the algorithm removed (level -1) ends a run and is not drawn.
    private static List<(int Start, int End, int Level)> Runs(sbyte[] levels)
    {
        var runs = new List<(int, int, int)>();
        int start = 0;
        for (int i = 1; i <= levels.Length; i++)
        {
            if (i < levels.Length && levels[i] == levels[start]) continue;
            if (levels[start] >= 0) runs.Add((start, i, levels[start]));
            start = i;
        }
        return runs;
    }

    // L2 on whole runs: from the highest level down to the lowest odd one, turn every stretch at that level or above.
    private static void Reorder(List<(int Start, int End, int Level)> runs)
    {
        if (runs.Count == 0) return;
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
    }
}
