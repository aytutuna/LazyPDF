using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TurkishAndFontTests
{
    [Fact]
    public void TurkishLettersComeFromTheFontSourceAndAreReported()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET");
        var editor = new PageEditor(session, 0, new EditArialSource());
        var result = editor.ReplaceText(EditKit.Find(session, "world"), "dünya ğışŞİ");
        Assert.True(result.Done, result.Problem);
        Assert.NotEmpty(result.Substitutions);
        Assert.Contains("ğ", result.Substitutions[0].Characters);
        Assert.Contains("Hello dünya ğışŞİ", EditKit.Text(session));
        Assert.Contains("ğışŞİ", EditKit.Pig(session));
    }

    [Fact]
    public void WithoutAFontSourceTheEditIsRefusedAndNothingIsCommitted()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "world"), "ğ");
        Assert.False(result.Done);
        Assert.Equal(EditingText.NoFont, result.Problem);
        Assert.False(session.CanUndo);
        Assert.Equal("Hello world", EditKit.Text(session).Trim());
    }

    [Fact]
    public void WinAnsiLettersNeedNoSubstitution()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "world"), "café");
        Assert.True(result.Done, result.Problem);
        Assert.Empty(result.Substitutions);
        Assert.Contains("café", EditKit.Text(session));
    }

    [Fact]
    public void ASubsetCidFontIsReusedForItsOwnLetters()
    {
        var session = PdfEditSession.Open(EditFixtures.EmbeddedLine("Hello world"));
        var result = new PageEditor(session, 0, new EditArialSource()).ReplaceText(EditKit.Find(session, "world"), "lower");
        Assert.True(result.Done, result.Problem);
        Assert.Empty(result.Substitutions);
        Assert.Equal("Hello lower", EditKit.Text(session).Trim());
        Assert.Contains("Hello lower", EditKit.Pig(session));
    }

    [Fact]
    public void ASubsetCidFontLackingALetterGetsAMatchingFont()
    {
        var session = PdfEditSession.Open(EditFixtures.EmbeddedLine("Hello world"));
        var result = new PageEditor(session, 0, new EditArialSource()).ReplaceText(EditKit.Find(session, "world"), "quizğ");
        Assert.True(result.Done, result.Problem);
        var sub = Assert.Single(result.Substitutions);
        Assert.Contains("q", sub.Characters);
        Assert.True(sub.Embedded);
        Assert.Contains("Hello quizğ", EditKit.Text(session));
        Assert.Contains("quizğ", EditKit.Pig(session));
    }

    [Fact]
    public void AWholeEmbeddedFontTakesNewLettersThroughItsOwnCmap()
    {
        var session = PdfEditSession.Open(EditFixtures.FullCidLine("Hello world"));
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "world"), "quiz ğş");
        Assert.True(result.Done, result.Problem);
        Assert.Empty(result.Substitutions);
        Assert.Contains("Hello quiz ğş", EditKit.Text(session));
        Assert.Contains("quiz ğş", EditKit.Pig(session));
    }
}
