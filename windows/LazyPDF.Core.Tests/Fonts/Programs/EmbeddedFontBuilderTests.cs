using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EmbeddedFontBuilderTests
{
    private const string Turkish = "Şğıİ Çalışma ÖĞRETMEN dünya ÜÇ çöğüşıİ";

    private static byte[] SetFsType(byte[] font, int fsType)
    {
        var copy = (byte[])font.Clone();
        var os2 = ProgramFonts.TableOffset(copy, "OS/2");
        copy[os2 + 8] = (byte)(fsType >> 8);
        copy[os2 + 9] = (byte)fsType;
        return copy;
    }

    [Fact]
    public void TurkishTextGetsACodeForEveryLetter()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;

        var font = EmbeddedFontBuilder.Build(data, [Turkish], out var status)!;

        Assert.Equal(EmbedStatus.Ok, status);
        Assert.False(font.IsCff);
        Assert.True(font.IsSubset);
        Assert.Matches(new Regex("^[A-Z]{6}\\+Arial"), font.BaseFont);
        Assert.Empty(font.Missing);
        foreach (var rune in Turkish.EnumerateRunes().Where(r => r.Value != ' '))
            Assert.True(font.Codes.ContainsKey(rune.Value), rune.ToString());
        foreach (var cp in new[] { 0x011F, 0x011E, 0x015F, 0x015E, 0x0131, 0x0130 })
            Assert.NotEqual(0, font.Codes[cp]);

        var subset = TrueTypeFont.TryParse(font.Program)!;
        foreach (var (cp, code) in font.Codes)
        {
            var original = source.GlyphForCodePoint(cp);
            Assert.Equal(source.GetOutline(original)!.Segments, subset.GetOutline(code)!.Segments);
            Assert.Equal(source.GetAdvance(original), subset.GetAdvance(code));
        }
    }

    [Fact]
    public void EncodeWritesTwoByteCodesThatToUnicodeReverses()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var font = EmbeddedFontBuilder.Build(data, [Turkish, "extra"], out _)!;

        var bytes = font.Encode(Turkish);
        var back = font.ToUnicode();

        Assert.Equal(Turkish.Length * 2, bytes.Length);
        var text = string.Concat(Enumerable.Range(0, bytes.Length / 2).Select(i => char.ConvertFromUtf32(back[(bytes[2 * i] << 8) | bytes[2 * i + 1]])));
        Assert.Equal(Turkish, text);
    }

    [Fact]
    public void WidthsAreInThousandthsAndGroupedInRuns()
    {
        if (ProgramFonts.Windows("times.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;
        var font = EmbeddedFontBuilder.Build(data, ["abcdefgh ğ"], out _)!;

        var all = new Dictionary<int, int>();
        foreach (var run in font.Widths)
            for (var i = 0; i < run.Widths.Count; i++) all.Add(run.FirstCid + i, run.Widths[i]);

        Assert.Equal(font.Codes.Count, all.Count);
        foreach (var (cp, code) in font.Codes)
            Assert.Equal((int)Math.Round(source.GetAdvance(source.GlyphForCodePoint(cp)) * 1000.0 / source.UnitsPerEm), all[code]);
        Assert.True(font.Widths.Count < font.Codes.Count, "consecutive codes share an entry");
        for (var i = 1; i < font.Widths.Count; i++)
            Assert.True(font.Widths[i].FirstCid > font.Widths[i - 1].FirstCid + font.Widths[i - 1].Widths.Count);
        Assert.Equal(1000, font.DefaultWidth);
    }

    [Fact]
    public void CharactersTheFontLacksAreReportedAndEncodeAsNotdef()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        var font = EmbeddedFontBuilder.Build(data, ["a中\U0001F600b"], out var status)!;

        Assert.Equal(EmbedStatus.Ok, status);
        Assert.Equal(new[] { 0x4E2D, 0x1F600 }, font.Missing.ToArray());
        Assert.False(font.Codes.ContainsKey(0x4E2D));
        var bytes = font.Encode("a中b");
        Assert.Equal(new byte[] { 0, 0 }, bytes[2..4]);
        Assert.NotEqual(new byte[] { 0, 0 }, bytes[0..2]);
    }

    [Fact]
    public void ControlCharactersAndEmptyTextAreHarmless()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        var font = EmbeddedFontBuilder.Build(data, ["a\r\n\tb", ""], out _)!;
        Assert.Equal(2, font.Codes.Count);
        Assert.Empty(font.Missing);

        var none = EmbeddedFontBuilder.Build(data, [], out var status)!;
        Assert.Equal(EmbedStatus.Ok, status);
        Assert.Empty(none.Codes);
        Assert.Empty(none.Widths);
        Assert.Equal(1, TrueTypeFont.TryParse(none.Program)!.GlyphCount);
    }

    [Fact]
    public void DescriptorValuesAreScaledToThousandths()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        var d = EmbeddedFontBuilder.Build(data, ["A"], out _)!.Descriptor;

        Assert.Equal(32, d.Flags & 32);
        Assert.Equal(0, d.Flags & 64);
        Assert.Equal(0, d.ItalicAngle);
        Assert.Equal(905, d.Ascent);
        Assert.True(d.Descent < 0);
        Assert.InRange(d.CapHeight, 600, 800);
        Assert.InRange(d.StemV, 40, 200);
        Assert.Equal(4, d.FontBBox.Length);
        Assert.True(d.FontBBox[2] > d.FontBBox[0] && d.FontBBox[3] > d.FontBBox[1]);
    }

    [Fact]
    public void ItalicFontSetsTheItalicFlag()
    {
        if (ProgramFonts.Windows("ariali.ttf") is not { } data) return;

        var d = EmbeddedFontBuilder.Build(data, ["A"], out _)!.Descriptor;

        Assert.Equal(64, d.Flags & 64);
        Assert.True(d.ItalicAngle < 0);
    }

    [Fact]
    public void RestrictedFontsAreRefused()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        Assert.Null(EmbeddedFontBuilder.Build(SetFsType(data, 2), ["a"], out var status));
        Assert.Equal(EmbedStatus.EmbeddingForbidden, status);
        Assert.Null(EmbeddedFontBuilder.Build(SetFsType(data, 0x200), ["a"], out status));
        Assert.Equal(EmbedStatus.EmbeddingForbidden, status);
    }

    [Fact]
    public void FontThatForbidsSubsettingIsEmbeddedWholeWithGlyphIdsAsCodes()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var patched = SetFsType(data, 0x100);
        var source = TrueTypeFont.TryParse(patched)!;

        var font = EmbeddedFontBuilder.Build(patched, ["Şğ"], out var status)!;

        Assert.Equal(EmbedStatus.Ok, status);
        Assert.False(font.IsSubset);
        Assert.Same(patched, font.Program);
        Assert.Equal("Arial", font.BaseFont.Replace("MT", ""));
        Assert.Equal(source.GlyphForCodePoint(0x011F), font.Codes[0x011F]);
    }

    [Fact]
    public void OpenTypeCffIsEmbeddedWholeAsCffFont()
    {
        if (ProgramFonts.Otf() is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;

        var font = EmbeddedFontBuilder.Build(data, ["Şğıİ"], out var status)!;

        Assert.Equal(EmbedStatus.Ok, status);
        Assert.True(font.IsCff);
        Assert.False(font.IsSubset);
        Assert.Same(data, font.Program);
        Assert.Equal(source.GlyphForCodePoint(0x015E), font.Codes[0x015E]);
        Assert.DoesNotContain("+", font.BaseFont);
        Assert.Equal(4, font.Codes.Count);
    }

    [Fact]
    public void CollectionMembersAreSubsetButNeverEmbeddedWhole()
    {
        if (ProgramFonts.Windows("msgothic.ttc") is not { } data) return;
        var source = TrueTypeFont.TryParse(data, 0)!;

        var font = EmbeddedFontBuilder.Build(data, ["あいう"], out var status, 0);

        if (!source.EmbeddingAllowed)
        {
            Assert.Null(font);
            Assert.Equal(EmbedStatus.EmbeddingForbidden, status);
            return;
        }
        Assert.NotNull(font);
        Assert.True(font.IsSubset);
        Assert.Equal(3, font.Codes.Count);
        Assert.Null(EmbeddedFontBuilder.Build(data, ["あ"], out status, 99));
        Assert.Equal(EmbedStatus.Unreadable, status);
    }

    [Fact]
    public void SameInputGivesSameBytesAndTextChangesTheTag()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        var a = EmbeddedFontBuilder.Build(data, ["abc"], out _)!;
        var b = EmbeddedFontBuilder.Build(data, ["abc"], out _)!;
        var c = EmbeddedFontBuilder.Build(data, ["abd"], out _)!;

        Assert.Equal(a.Program, b.Program);
        Assert.Equal(a.BaseFont, b.BaseFont);
        Assert.NotEqual(a.BaseFont, c.BaseFont);
    }

    [Fact]
    public void GarbageIsUnreadable()
    {
        Assert.Null(EmbeddedFontBuilder.Build([], ["a"], out var status));
        Assert.Equal(EmbedStatus.Unreadable, status);
        Assert.Null(EmbeddedFontBuilder.Build(new byte[200], ["a"], out status));
        Assert.Equal(EmbedStatus.Unreadable, status);
    }
}
