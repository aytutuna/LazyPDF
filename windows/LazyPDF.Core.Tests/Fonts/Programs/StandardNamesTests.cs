using System.Reflection;
using LazyPDF.Core;
using Xunit;
using UglyToad.PdfPig.Fonts.Encodings;

namespace LazyPDF.Core.Tests;

/// <summary>Checks the glyph name tables against the copies PdfPig carries.</summary>
public class StandardNamesTests
{
    private const BindingFlags Static = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

    private static readonly Assembly Fonts = typeof(StandardEncoding).Assembly;

    private static T Field<T>(string type, string name) =>
        (T)Fonts.GetType(type, throwOnError: true)!.GetField(name, Static)!.GetValue(null)!;

    [Fact]
    public void CffStringsMatch()
    {
        var theirs = Field<string[]>("UglyToad.PdfPig.Fonts.CompactFontFormat.CompactFontFormatStandardStrings", "StringIdentifierToString");
        Assert.Equal(theirs, StandardNames.CffStrings);
    }

    [Fact]
    public void MacintoshGlyphOrderMatches()
    {
        var theirs = Field<string[]>("UglyToad.PdfPig.Fonts.TrueType.WindowsGlyphList4", "MacGlyphNames");
        Assert.Equal(theirs, StandardNames.MacGlyphs);
    }

    [Fact]
    public void StandardEncodingMatches()
    {
        var theirs = StandardEncoding.Instance.CodeToNameMap;
        for (int code = 0; code < 256; code++)
        {
            var name = theirs.TryGetValue(code, out var n) && n != ".notdef" ? n : null;
            Assert.Equal(name, StandardNames.StandardEncoding[code]);
        }
    }

    [Theory]
    [InlineData("IsoAdobe")]
    [InlineData("Expert")]
    public void PredefinedCharsetsAgreeWithTheStrings(string charset)
    {
        var names = Field<IReadOnlyDictionary<int, string>>($"UglyToad.PdfPig.Fonts.CompactFontFormat.Charsets.CompactFontFormat{charset}Charset", "StringIdToName");
        foreach (var (sid, name) in names) Assert.Equal(name, StandardNames.CffStrings[sid]);
    }

    [Fact]
    public void TablesHaveTheSizesTheSpecsGive()
    {
        Assert.Equal(391, StandardNames.CffStrings.Length);
        Assert.Equal(258, StandardNames.MacGlyphs.Length);
        Assert.Equal(256, StandardNames.StandardEncoding.Length);
        Assert.Equal(256, StandardNames.StandardEncodingSids.Length);
        Assert.Equal(StandardNames.CffStrings.Length, StandardNames.CffStrings.Distinct().Count());
    }

    [Fact]
    public void StandardEncodingSidsNameTheSameGlyphs()
    {
        for (int code = 0; code < 256; code++)
        {
            var name = StandardNames.StandardEncoding[code];
            var sid = StandardNames.StandardEncodingSids[code];
            if (name is null) Assert.Equal(0, sid);
            else Assert.Equal(name, StandardNames.CffStrings[sid]);
        }
    }
}
