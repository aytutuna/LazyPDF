using System.Windows.Automation.Text;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.TextPdf;

namespace LazyPDF.App.Tests;

public sealed class PageUiaTextTests
{
    [Fact]
    public void LinesBlocksAndCellsAreSeparatedAndThePageEndsWithALineFeed()
    {
        var t = Page(Line(100, 700, "Hello  world") + Line(100, 688, "next") + Line(100, 650, "far") + Line(300, 650, "cell"));
        Assert.Equal("Hello  world\nnext\n\nfar\tcell\n", t.Text);
    }

    [Fact]
    public void ALineThatStartsWithASpaceStillGetsItsSeparator()
    {
        var t = Page(Line(100, 700, "one") + Line(100, 688, "  two  "));
        Assert.Equal("one\ntwo\n", t.Text);
    }

    [Fact]
    public void SoftHyphensAreDroppedEvenAtTheEndOfALine()
    {
        var t = Page(Line(100, 700, "soft­") + Line(100, 688, "hy­phen"));
        Assert.Equal("soft\nhyphen\n", t.Text);
    }

    [Fact]
    public void CharactersWithoutTextTakeNoPlace()
    {
        var pages = Pages(Line(100, 700, "a\u0080b"));
        var t = PageUiaText.Of(pages[0]);
        Assert.Equal("ab\n", t.Text);
        var chars = pages[0].Chars;
        int empty = Enumerable.Range(0, chars.Count).Single(i => chars[i].Text.Length == 0);
        Assert.Equal(t.OffsetOf(empty + 1), t.OffsetOf(empty));
    }

    [Fact]
    public void EveryKeptCharacterIsFoundAtItsOffset()
    {
        var pages = Pages(Line(100, 700, "Hello  wﬁnd") + Line(100, 688, " sp\U0001F600ce ") + Line(100, 650, "end­") + Line(300, 650, "cell"));
        var t = PageUiaText.Of(pages[0]);
        foreach (var c in pages[0].Chars.Where(c => !c.IsSpace && c.Text.Length > 0 && c.Text != "­"))
        {
            int at = t.OffsetOf(c.Index);
            Assert.Equal(c.Text, t.Text.Substring(at, c.Text.Length));
            Assert.Equal(c.Index, t.CharStart(at));
        }
    }

    [Fact]
    public void AUnitInsideALigatureBelongsToItsCharacter()
    {
        var pages = Pages(Line(100, 700, "afﬁx"));
        var t = PageUiaText.Of(pages[0]);
        Assert.Equal("affix\n", t.Text);
        int ligature = pages[0].Chars.Single(c => c.Text == "fi").Index;
        int at = t.OffsetOf(ligature);
        Assert.Equal(ligature, t.CharStart(at + 1));
        Assert.Equal(ligature + 1, t.CharEnd(at + 1));
        Assert.Equal(ligature + 1, t.CharEnd(at + 2));
    }

    [Fact]
    public void SeparatorsAndThePageBreakBelongToNoCharacter()
    {
        var pages = Pages(Line(100, 700, "ab") + Line(100, 688, "cd"));
        var t = PageUiaText.Of(pages[0]);
        Assert.Equal("ab\ncd\n", t.Text);
        Assert.Equal(2, t.CharStart(2));
        Assert.Equal(2, t.CharEnd(3));
        Assert.Equal(4, t.CharEnd(6));
        Assert.Equal(6, t.OffsetOf(4));
    }

    [Fact]
    public void AnEmptyPageIsALineFeed()
    {
        var t = Page("");
        Assert.Equal("\n", t.Text);
        Assert.Equal(1, t.Length);
        Assert.Equal(1, t.OffsetOf(0));
        Assert.Equal(0, t.CharStart(0));
    }

    [Fact]
    public void UnitStartsFollowWordsLinesAndParagraphs()
    {
        var t = Page(Line(100, 700, "one two") + Line(100, 688, "three") + Line(100, 650, "four"));
        Assert.Equal("one two\nthree\n\nfour\n", t.Text);
        Assert.Equal([0, 4, 8, 15], t.Starts(TextUnit.Word));
        Assert.Equal([0, 8, 15], t.Starts(TextUnit.Line));
        Assert.Equal([0, 15], t.Starts(TextUnit.Paragraph));
        Assert.Equal([0], t.Starts(TextUnit.Page));
        Assert.Null(t.Starts(TextUnit.Character));
    }

    [Fact]
    public void FormatRunsChangeWithSizeOrColor()
    {
        var content = "BT /F1 10 Tf 100 700 Td (plain ) Tj /F1 14 Tf (big ) Tj 1 0 0 rg /F1 14 Tf (red) Tj ET\n" + Line(100, 684, "last");
        var t = Page(content);
        Assert.Equal("plain big red\nlast\n", t.Text);
        Assert.Equal([0, 6, 10, 14], t.Starts(TextUnit.Format));
    }

    [Fact]
    public void AGapBetweenRunsIsAnImpliedSpaceThatKeepsTheFormatRun()
    {
        var pages = Pages("BT /F1 10 Tf 100 700 Td (ab) Tj 14 0 Td (cd) Tj ET\n");
        var t = PageUiaText.Of(pages[0]);
        Assert.Equal("ab cd\n", t.Text);
        Assert.Contains(pages[0].Chars, c => c.IsSpace && c.Font is null);
        Assert.Equal([0], t.Starts(TextUnit.Format));
        Assert.Equal([0, 3], t.Starts(TextUnit.Word));
    }

    [Fact]
    public void ALineWithNothingToKeepAddsNoSeparatorAndItsCharactersTakeTheNextOffset()
    {
        var pages = Pages(Line(100, 700, "ab") + Line(100, 688, "  \u0080 ") + Line(100, 676, "cd"));
        var t = PageUiaText.Of(pages[0]);
        Assert.Equal("ab\ncd\n", t.Text);
        int c = pages[0].Chars.Single(x => x.Text == "c").Index;
        for (int i = 2; i < c; i++) Assert.Equal(3, t.OffsetOf(i));
        Assert.Equal(c, t.CharStart(3));
        Assert.Equal(c, t.CharEnd(3));
        Assert.Equal([0, 3], t.Starts(TextUnit.Line));
    }

    [Fact]
    public void TheTextIsBuiltOncePerPage()
    {
        var page = Pages(Line(100, 700, "x"))[0];
        Assert.Same(PageUiaText.Of(page), PageUiaText.Of(page));
    }
}
