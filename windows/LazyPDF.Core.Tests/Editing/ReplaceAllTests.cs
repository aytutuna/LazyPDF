using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ReplaceAllTests
{
    private static PdfEditSession Open(params string[] contents)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", contents.Select((_, i) => $"{10 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {contents.Length} /MediaBox [0 0 600 800]>>");
        pdf.Obj(5, EditKit.Helvetica);
        pdf.Obj(7, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-V /DescendantFonts [<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial " +
            "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 600>>] /ToUnicode 8 0 R>>");
        pdf.Stream(8, "", "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def /CMapType 2 def " +
            "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfrange <0041> <005A> <0041> endbfrange endcmap end end");
        for (int i = 0; i < contents.Length; i++)
        {
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {30 + i} 0 R /Resources <</Font <</F1 5 0 R /F3 7 0 R>>>>>>");
            pdf.Stream(30 + i, "", contents[i]);
        }
        return PdfEditSession.Open(pdf.Finish());
    }

    private static string Page(PdfEditSession session, int index)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        return TextPage.Create(document, document.Pages[index]).Text.Trim();
    }

    [Fact]
    public void EveryMatchOnEveryPageIsReplacedInOneUndoStep()
    {
        var session = Open(
            "BT /F1 12 Tf 50 700 Td (The colour of colour) Tj 0 -20 Td (Colour wheel) Tj ET",
            "BT /F1 12 Tf 50 700 Td (no match here) Tj ET",
            "BT /F1 12 Tf 50 700 Td [(a co) 10 (lour)] TJ ET");
        var report = TextReplacer.ReplaceAll(session, "colour", "color");
        Assert.Equal(4, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal([0, 2], report.Pages);
        Assert.Equal("The color of color\ncolor wheel", Page(session, 0));
        Assert.Equal("a color", Page(session, 2));
        Assert.Equal("Replace text", session.UndoLabel);
        Assert.True(session.Undo());
        Assert.Equal("The colour of colour\nColour wheel", Page(session, 0));
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void TheOptionsOfTheSearchApply()
    {
        string content = "BT /F1 12 Tf 50 700 Td (cat Cat concat) Tj ET";
        var session = Open(content);
        TextReplacer.ReplaceAll(session, "cat", "dog", new TextSearchOptions(MatchCase: true, WholeWord: true));
        Assert.Equal("dog Cat concat", Page(session, 0));
        session = Open(content);
        TextReplacer.ReplaceAll(session, "cat", "dog");
        Assert.Equal("dog dog condog", Page(session, 0));
    }

    [Fact]
    public void ARegularExpressionReplacementTakesGroups()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td (12 apples and 7 apples) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(\d+) apples", "$1 pears", new TextSearchOptions(Regex: true));
        Assert.Equal(2, report.Replaced);
        Assert.Equal("12 pears and 7 pears", Page(session, 0));
    }

    [Fact]
    public void WhatCannotBeReplacedIsReportedAndLeftAlone()
    {
        var session = Open(
            "BT /F1 12 Tf 50 700 Td (a world here) Tj ET",
            "BT /F3 12 Tf 50 700 Td <0057004F0052004C0044> Tj ET",
            "BT /F1 12 Tf 50 700 Td (the wor) Tj 0 -14 Td (ld ends) Tj ET");
        var report = TextReplacer.ReplaceAll(session, "world", "globe");
        Assert.Equal(1, report.Replaced);
        var failure = Assert.Single(report.Failed);
        Assert.Equal(1, failure.Page);
        Assert.Equal(EditingText.Vertical, failure.Reason);
        Assert.Equal("a globe here", Page(session, 0));
        Assert.Equal("WORLD", Page(session, 1));
    }

    [Fact]
    public void LettersNoFontHasAreReportedPerMatch()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td (one two two) Tj ET");
        var report = TextReplacer.ReplaceAll(session, "two", "ğ");
        Assert.Equal(0, report.Replaced);
        Assert.Equal(2, report.Failed.Count);
        Assert.All(report.Failed, f => Assert.Equal(EditingText.NoFont, f.Reason));
        Assert.False(session.CanUndo);
        report = TextReplacer.ReplaceAll(session, "two", "ğ", fonts: new EditArialSource());
        Assert.Equal(2, report.Replaced);
        Assert.Equal("one ğ ğ", Page(session, 0));
        Assert.Single(report.Substitutions.Select(s => s.Characters).Distinct());
    }

    [Fact]
    public void ManyMatchesInOneRunKeepTheTextAround()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td (aa bb aa bb aa bb aa) Tj ET");
        var report = TextReplacer.ReplaceAll(session, "aa", "xyz");
        Assert.Equal(4, report.Replaced);
        Assert.Equal("xyz bb xyz bb xyz bb xyz", Page(session, 0));
    }
}
