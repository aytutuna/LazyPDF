using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Operators put round a run of glyphs must reach those glyphs and nothing the stream sets again or closes in between.
public class RunCutTests
{
    private static readonly RgbColor Red = new(255, 0, 0);

    private static TextRange Across(PdfEditSession session, string from, string to) =>
        new(EditKit.Find(session, from).Start, EditKit.Find(session, to).End);

    [Fact]
    public void RestyleReachesTextObjectsThatSetTheirOwnColourAndFont()
    {
        string content = "BT /F1 12 Tf 0 0 0 rg 50 700 Td (line one) Tj ET BT /F1 12 Tf 0 0 0 rg 50 680 Td (line two) Tj ET";
        var session = EditKit.Session(content);
        var one = EditKit.Find(session, "line one");
        var two = EditKit.Find(session, "line two");
        var result = new PageEditor(session, 0).SetTextStyle([new TextRange(one.Start, two.End)], new TextStyleChange(Color: Red, Size: 20));
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.All(EditKit.Of(shown, "line one"), g => Assert.Equal((Red, 20.0), (g.Color, g.Size)));
        Assert.All(EditKit.Of(shown, "line two"), g => Assert.Equal((Red, 20.0), (g.Color, g.Size)));
    }

    [Fact]
    public void RestyleReachesTextAfterACharacterSpacingChangeInsideTheRange()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (abc) Tj 0.5 Tc (def) Tj ET BT 50 600 Td (tail) Tj ET");
        var result = new PageEditor(session, 0).SetTextStyle([Across(session, "abc", "def")], new TextStyleChange(CharSpacing: 2));
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.All(EditKit.Of(shown, "abc"), g => Assert.Equal(2, g.Tc));
        Assert.All(EditKit.Of(shown, "def"), g => Assert.Equal(2, g.Tc));
        Assert.All(EditKit.Of(shown, "tail"), g => Assert.Equal(0.5, g.Tc));
    }

    [Fact]
    public void StrikesInTheirOwnQGroupsAreJoinedByAJustifyAndByARestyle()
    {
        string content = "q BT /F1 12 Tf 14 TL 50 700 Td (Hello big) Tj ET Q q BT /F1 12 Tf 50.2 700 Td (Hello big) Tj ET Q q BT /F1 12 Tf 50 686 Td (a much longer second line here) Tj ET Q";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var result = editor.SetAlignment(editor.Objects.OfType<TextObject>().Single(), TextAlignment.Justify);
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.True(shown[5].Tw > 0);
        Assert.Equal(shown[5].Tw, shown[14].Tw);

        editor = new PageEditor(session, 0);
        var restyle = editor.SetTextStyle([Across(session, "Hello", "big")], new TextStyleChange(Color: Red));
        Assert.True(restyle.Done, restyle.Problem);
        Assert.All(EditKit.Shown(session).Take(18).Where(g => g.Text != " "), g => Assert.Equal(Red, g.Color));
    }

    [Fact]
    public void SpacingOfTheQuoteOperatorIsPutBackAfterNewTextInAnotherStyle()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td 2 1 (abc def) \" ( ghi) Tj ET");
        var editor = new PageEditor(session, 0, new EditArialSource());
        var result = editor.SetTextStyle([EditKit.Find(session, "abc")], new TextStyleChange(Bold: true, CharSpacing: 4));
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.All(EditKit.Of(shown, "abc"), g => Assert.Equal(4, g.Tc));
        Assert.All(EditKit.Of(shown, "def"), g => Assert.Equal(1, g.Tc));
        Assert.All(EditKit.Of(shown, "ghi"), g => Assert.Equal(1, g.Tc));
    }

    [Fact]
    public void AHiddenCopyThatCannotShowTheNewLettersIsCutAndTheEditGoesThrough()
    {
        const string Cut = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 66 /Widths [600 600] /Encoding /WinAnsiEncoding>>";
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (AB) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB) Tj ET",
            more: pdf => pdf.Obj(7, Cut), resources: "/Font <</F1 5 0 R /F3 7 0 R>>");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "AB"), "XY");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("XY", EditKit.Text(session).Trim());
        Assert.DoesNotContain("(AB)", EditKit.Latin(session));
    }
}
