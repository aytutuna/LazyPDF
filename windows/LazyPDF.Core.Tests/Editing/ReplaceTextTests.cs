using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ReplaceTextTests
{
    private const string Line = "BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET";

    [Fact]
    public void ReplacesAWordInOneString()
    {
        var session = EditKit.Session(Line);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("Hello grand world", EditKit.Text(session).Trim());
        Assert.Contains("Hello grand world", EditKit.Pig(session));
        Assert.True(session.CanUndo);
    }

    [Fact]
    public void ALongerWordMovesTheRestOfTheRunAndLeavesOtherRuns()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello brave) Tj 100 0 Td (tail) Tj ET");
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "braver and bolder");
        Assert.True(result.Done, result.Problem);
        var after = EditKit.Glyphs(session);
        Assert.Equal("Hello braver and bolder", string.Concat(after.Take(23).Select(g => g.Text)));
        // The first glyph and the other run are where they were.
        Assert.Equal(before[0], after[0]);
        Assert.Equal(before[^1], after[^1]);
        Assert.True(result.Overlaps);
    }

    [Fact]
    public void WordsOfATJArrayKeepTheirKerning()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td [(Hel) -120 (lo) 300 (wor) -50 (ld)] TJ ET");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "lo"), "p");
        Assert.True(result.Done, result.Problem);
        string content = EditKit.Latin(session);
        Assert.Contains("(Hel) -120 (p) 300 (wor) -50 (ld)", content.Replace("[", "").Replace("]", ""));
        Assert.Contains("Help", EditKit.Pig(session));
    }

    [Fact]
    public void DeleteKeepsTheRestInPlace()
    {
        var session = EditKit.Session(Line);
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0).DeleteText(EditKit.Find(session, "brave"));
        Assert.True(result.Done, result.Problem);
        var after = EditKit.Glyphs(session);
        Assert.Equal("Hello  world", string.Concat(after.Select(g => g.Text)));
        Assert.Equal(before[^1], after[^1]);
        Assert.Equal(before[0], after[0]);
    }

    [Fact]
    public void InsertGoesBeforeTheCharacter()
    {
        var session = EditKit.Session(Line);
        var text = TextPage.Create(session.Document, session.Document.Pages[0]);
        int at = text.Text.IndexOf("world", StringComparison.Ordinal);
        var result = new PageEditor(session, 0).InsertText(at, "big ");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("Hello brave big world", EditKit.Text(session).Trim());
    }

    [Fact]
    public void OperatorsOutsideTheEditKeepTheirBytes()
    {
        string content = "q 1 0 0 1 5 5 cm 0.5 g 10 10 100 100 re f Q\nBT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET\nq 2 w 0 0 m 50 50 l S Q";
        var session = EditKit.Session(content);
        new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        string after = EditKit.Latin(session);
        Assert.StartsWith("q 1 0 0 1 5 5 cm 0.5 g 10 10 100 100 re f Q\nBT /F1 12 Tf 50 700 Td ", after);
        Assert.EndsWith(" ET\nq 2 w 0 0 m 50 50 l S Q", after);
    }

    [Fact]
    public void ARunThatStartsInsideTheCutKeepsItsTextWhereItWas()
    {
        // The word is in two text objects, the second going on with " code"; the new word goes in the first.
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Sou) Tj ET BT /F1 12 Tf 71.348 700 Td (rce code) Tj ET");
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "Source"), "ourceS");
        Assert.True(result.Done, result.Problem);
        var after = EditKit.Glyphs(session);
        Assert.Equal("ourceS code", string.Concat(after.Select(g => g.Text)));
        Assert.Equal(before.Skip(6).Select(g => (g.Text, g.X)), after.Skip(6).Select(g => (g.Text, g.X)));
    }

    [Fact]
    public void AWordInTwoSizesTakesItsNewLettersInTheSameSizes()
    {
        var session = EditKit.Session("BT /F1 24 Tf 50 700 Td (P) Tj /F1 12 Tf (RINTED) Tj ET");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "PRINTED"), "RINTEDP");
        Assert.True(result.Done, result.Problem);
        var glyphs = EditKit.Glyphs(session);
        Assert.Equal("RINTEDP", string.Concat(glyphs.Select(g => g.Text)));
        Assert.Equal([24, 12, 12, 12, 12, 12, 12], glyphs.Select(g => g.Size));
        Assert.Contains("RINTEDP", EditKit.Text(session));
    }

    [Fact]
    public void UndoBringsTheOldTextBack()
    {
        var session = EditKit.Session(Line);
        new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(session.Undo());
        Assert.Equal("Hello brave world", EditKit.Text(session).Trim());
        Assert.True(session.Redo());
        Assert.Equal("Hello grand world", EditKit.Text(session).Trim());
    }
}
