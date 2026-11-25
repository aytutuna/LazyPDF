using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EditShapedFontTests
{
    // Joined letters take the initial and final forms; a letter alone keeps the cmap glyph, as a real shaper's isolated form would differ from both.
    private sealed class JoiningFonts : IFontSource, IShaper
    {
        public FontFile? Find(string family, FontStyles style) => new(TrueTypeBuilder.BuildScript());

        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language)
        {
            if (text.Length < 2 || text.Any(c => c != 'ب')) return new CmapShaper().Shape(text, font, rightToLeft, language);
            var glyphs = text.Select((_, i) =>
                new ShapedGlyph(i == text.Length - 1 ? TrueTypeBuilder.BehFinal : TrueTypeBuilder.BehInitial, 600, 0, 0, i)).ToList();
            if (rightToLeft) glyphs.Reverse();
            return glyphs;
        }
    }

    [Fact]
    public void JoinedArabicTypedIntoEditTextHasNoNotdefCodes()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET");
        Assert.True(new PageEditor(session, 0, new JoiningFonts()).ReplaceText(EditKit.Find(session, "world"), "بب").Done);
        var document = PdfDocument.Open(session.Current.ToArray());
        string content = Encoding.Latin1.GetString(document.Pages[0].Contents());
        var shown = Regex.Matches(content, "<([0-9A-Fa-f]+)>").Select(m => m.Groups[1].Value).ToList();
        Assert.NotEmpty(shown);
        foreach (string hex in shown)
            for (int i = 0; i < hex.Length; i += 4) Assert.NotEqual("0000", hex.Substring(i, 4));
    }
}
