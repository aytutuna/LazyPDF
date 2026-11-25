using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.TextFormatting;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>Shapes a run with WPF's text formatter: joining forms, ligatures and mark placement from the font's own tables.</summary>
internal static class WpfShaper
{
    // Advances and offsets come out in em fractions of this size, so they are already in 1/1000 em.
    private const double Size = 1000;

    public static List<ShapedGlyph>? Shape(Typeface typeface, string text, bool rightToLeft, string? language)
    {
        // Latin and the like stay with Core's cmap shaper, so ligatures and kerning do not change text that already worked.
        if (!text.EnumerateRunes().Any(r => Scripts.IsArabic(r.Value) || Scripts.IsHebrew(r.Value))) return null;
        if (!typeface.TryGetGlyphTypeface(out var glyphTypeface)) return null;

        // WPF applies its own bidi: it mirrors brackets in a right-to-left run (Core has done that already) and splits
        // at direction marks, which Core draws as nothing.
        var sent = new StringBuilder(text.Length);
        var origin = new List<int>(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            if (IsDirectionControl(text[i])) continue;
            char c = text[i];
            if (rightToLeft && !char.IsSurrogate(c)) c = (char)BidiData.Mirror(c);
            sent.Append(c);
            origin.Add(i);
        }
        if (sent.Length == 0) return [];

        var properties = new Properties(typeface, Culture(language));
        using var line = TextFormatter.Create(TextFormattingMode.Ideal).FormatLine(new Source(sent.ToString(), properties), 0, 1e6,
            new Paragraph(properties, rightToLeft ? FlowDirection.RightToLeft : FlowDirection.LeftToRight), null);

        // WPF caps the width of a line and breaks a very long run early; a prefix would leave the rest without glyphs.
        var indexedRuns = (line.GetIndexedGlyphRuns() ?? []).OrderBy(r => r.TextSourceCharacterIndex).ToList();
        if (line.Length < sent.Length || indexedRuns.Sum(r => r.TextSourceLength) < sent.Length) return null;

        // The glyphs of a run are in logical order, with offsets along the writing direction.
        var logical = new List<ShapedGlyph>();
        foreach (var indexed in indexedRuns)
        {
            var run = indexed.GlyphRun;
            // A font fallback or a direction switch inside the run is something this path does not place.
            if (run.GlyphTypeface.FontUri != glyphTypeface.FontUri || (run.BidiLevel & 1) != (rightToLeft ? 1 : 0)) return null;
            AddRun(logical, run, indexed.TextSourceCharacterIndex, sent.ToString(), origin);
        }
        if (rightToLeft)
        {
            logical.Reverse();
            for (int i = 0; i < logical.Count; i++) logical[i] = logical[i] with { XOffset = -logical[i].XOffset };
        }
        return logical;
    }

    private static void AddRun(List<ShapedGlyph> glyphs, GlyphRun run, int start, string sent, List<int> origin)
    {
        // The cluster map gives the first glyph of each character; a glyph belongs to the first character that
        // starts at or before it, so a ligature's second character and a decomposed glyph's extra glyphs share a cluster.
        var first = new int[run.GlyphIndices.Count];
        Array.Fill(first, -1);
        for (int c = 0; c < (run.ClusterMap?.Count ?? first.Length); c++)
        {
            int g = run.ClusterMap is null ? c : run.ClusterMap[c];
            if (g < first.Length && first[g] < 0) first[g] = c;
        }
        for (int j = 0, character = 0; j < first.Length; j++)
        {
            if (first[j] >= 0) character = first[j];
            int index = start + character;
            if (CmapShaper.IsInvisible(sent[index])) continue;
            var offset = run.GlyphOffsets is { } offsets ? offsets[j] : default;
            glyphs.Add(new ShapedGlyph(run.GlyphIndices[j], run.AdvanceWidths[j], offset.X, offset.Y, origin[index]));
        }
    }

    private static bool IsDirectionControl(char c) =>
        c is '‎' or '‏' or '؜' or (>= '‪' and <= '‮') or (>= '⁦' and <= '⁩');

    private static CultureInfo Culture(string? language)
    {
        try { return language is null ? CultureInfo.InvariantCulture : CultureInfo.GetCultureInfo(language); }
        catch (CultureNotFoundException) { return CultureInfo.InvariantCulture; }
    }

    private sealed class Properties(Typeface typeface, CultureInfo culture) : TextRunProperties
    {
        public override Typeface Typeface => typeface;
        public override double FontRenderingEmSize => Size;
        public override double FontHintingEmSize => Size;
        public override TextDecorationCollection? TextDecorations => null;
        public override Brush ForegroundBrush => Brushes.Black;
        public override Brush? BackgroundBrush => null;
        public override CultureInfo CultureInfo => culture;
        public override TextEffectCollection? TextEffects => null;
    }

    private sealed class Paragraph(TextRunProperties defaults, FlowDirection flow) : TextParagraphProperties
    {
        public override FlowDirection FlowDirection => flow;
        public override System.Windows.TextAlignment TextAlignment => System.Windows.TextAlignment.Left;
        public override double LineHeight => 0;
        public override bool FirstLineInParagraph => true;
        public override TextRunProperties DefaultTextRunProperties => defaults;
        public override TextWrapping TextWrapping => TextWrapping.NoWrap;
        public override TextMarkerProperties? TextMarkerProperties => null;
        public override double Indent => 0;
    }

    private sealed class Source(string text, TextRunProperties properties) : TextSource
    {
        public override System.Windows.Media.TextFormatting.TextRun GetTextRun(int index) =>
            index < text.Length ? new TextCharacters(text, index, text.Length - index, properties) : new TextEndOfParagraph(1);

        public override TextSpan<CultureSpecificCharacterBufferRange>? GetPrecedingText(int index) => null;

        public override int GetTextEffectCharacterIndexFromTextSourceCharacterIndex(int index) => index;
    }
}
