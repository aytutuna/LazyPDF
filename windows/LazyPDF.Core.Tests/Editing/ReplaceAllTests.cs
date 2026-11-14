using System.Text;
using System.Text.RegularExpressions;
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
        // Codes 1, 2 and 3 are the ligature glyphs ffi, ff and fi; 4 and 5 are e and a with a combining mark.
        pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 1 /LastChar 255 /Widths [" + string.Join(' ', Enumerable.Repeat(500, 255)) + "] /ToUnicode 9 0 R>>");
        pdf.Stream(9, "", "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Y def /CMapType 2 def " +
            "1 begincodespacerange <00> <FF> endcodespacerange 5 beginbfchar <01> <006600660069> <02> <00660066> <03> <00660069> <04> <00650301> <05> <00610300> endbfchar endcmap end end");
        for (int i = 0; i < contents.Length; i++)
        {
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {30 + i} 0 R /Resources <</Font <</F1 5 0 R /F3 7 0 R /F4 6 0 R>> /Properties <</MC0 <</MCID 4 /Lang (en) /ActualText (hello world)>>>>>>>>");
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

    private static string Content(PdfEditSession session) => Encoding.Latin1.GetString(PdfDocument.Open(session.Current.ToArray()).Pages[0].Contents());

    private sealed class MarkedCollector : ContentVisitor
    {
        public List<MarkedContent> Marked { get; } = [];

        public override void BeginMarked(ContentContext context, MarkedContent marked) => Marked.Add(marked);
    }

    private const string Hello = "BT /F1 12 Tf 50 700 Td {0} BDC (hello world) Tj EMC ET";

    [Fact]
    public void AHitInsideReplacementTextKeepsTheRestOfIt()
    {
        var session = Open(string.Format(Hello, "/Span <</ActualText (hello world)>>"));
        var report = TextReplacer.ReplaceAll(session, "world", "globe");
        Assert.Equal(1, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal("hello globe", Page(session, 0));
        Assert.DoesNotContain("/ActualText", Content(session));
    }

    [Fact]
    public void AHitOnAllOfReplacementTextReplacesIt()
    {
        var session = Open(string.Format(Hello, "/Span <</ActualText (hello world)>>"));
        Assert.Equal(1, TextReplacer.ReplaceAll(session, "hello world", "bye").Replaced);
        Assert.Equal("bye", Page(session, 0));
    }

    [Fact]
    public void AHitOverTwoSpansKeepsTheTextOutsideIt()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (say hello wor)>> BDC (say hello wor) Tj EMC " +
            "/Span <</ActualText (ld again)>> BDC (ld again) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "world", "globe");
        Assert.Equal(1, report.Replaced);
        Assert.Equal("say hello globe again", Page(session, 0));
        Assert.DoesNotContain("/ActualText", Content(session));
    }

    [Fact]
    public void TheMatchIsFoundThroughCaseAndAccentFolding()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (caf\\351 World)>> BDC (cafe World) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "cafe", "tea", new TextSearchOptions(FoldDiacritics: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("tea World", Page(session, 0));
    }

    [Theory]
    [InlineData("/P <</MCID 3 /Lang (en) /ActualText (hello world)>>")]
    [InlineData("/P /MC0")]
    public void ATaggedSpanKeepsItsTagAndPropertiesWhenReplaced(string open)
    {
        var session = Open(string.Format(Hello, open));
        Assert.Equal(1, TextReplacer.ReplaceAll(session, "world", "globe").Replaced);
        Assert.Equal("hello globe", Page(session, 0));
        string content = Content(session);
        Assert.DoesNotContain("/ActualText", content);
        var visitor = new MarkedCollector();
        var document = PdfDocument.Open(session.Current.ToArray());
        new ContentInterpreter(document).Run(document.Pages[0], visitor);
        Assert.Contains(visitor.Marked, m => m.Tag == "P" && m.Mcid is not null && m.Properties!.ContainsKey("Lang"));
    }

    [Fact]
    public void ASpanWithOnlyTheTextBecomesPlainMarkedContent()
    {
        var session = Open(string.Format(Hello, "/Span <</ActualText (hello world)>>"));
        TextReplacer.ReplaceAll(session, "world", "globe");
        Assert.Contains("/Span BMC", Content(session));
    }

    [Fact]
    public void EveryEnclosingSpanIsNeutralized()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (hello world)>> BDC /Span <</ActualText (hello)>> BDC (hello) Tj EMC ( world) Tj EMC ET");
        Assert.Equal(1, TextReplacer.ReplaceAll(session, "world", "globe").Replaced);
        Assert.Equal("hello globe", Page(session, 0));
        Assert.Equal(0, Regex.Count(Content(session), "/ActualText"));
    }

    [Fact]
    public void DeletingTaggedReplacementTextKeepsItsTag()
    {
        var session = Open(string.Format(Hello, "/P <</MCID 3 /Lang (en) /ActualText (hello world)>>"));
        var editor = new PageEditor(session, 0);
        Assert.True(editor.DeleteText(Assert.Single(editor.Objects.OfType<TextObject>()).Range).Done);
        string content = Content(session);
        Assert.Matches(@"/P\s*<<[^>]*/MCID 3[^>]*/Lang \(en\)", content);
        Assert.DoesNotContain("/ActualText", content);
        Assert.Equal("", Page(session, 0));
    }

    [Fact]
    public void GroupsOfARegularExpressionInsideASpanExpandToTheirOwnText()
    {
        var session = Open(string.Format(Hello, "/Span <</ActualText (hello world)>>"));
        var report = TextReplacer.ReplaceAll(session, "w(or)ld", "[$1]", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("hello [or]", Page(session, 0));
        session = Open(string.Format(Hello, "/Span <</ActualText (hello world)>>"));
        TextReplacer.ReplaceAll(session, "w(or)ld", "<$&|$`|$'>", new TextSearchOptions(Regex: true));
        Assert.Equal("hello <world|hello |>", Page(session, 0));
    }

    [Theory]
    [InlineData("hi hi", "x x", 2)]
    [InlineData("hi hi hi", "x x x", 3)]
    [InlineData("a hi b hi", "a x b x", 2)]
    public void EveryHitInsideOneSpanIsReplaced(string text, string expected, int count)
    {
        var session = Open($"BT /F1 12 Tf 50 700 Td /Span <</ActualText ({text})>> BDC ({text}) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "hi", "x");
        Assert.Equal(count, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal(expected, Page(session, 0));
    }

    [Fact]
    public void ASpanEndingInAHyphenAtALineEndKeepsItAroundAHit()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (ab-)>> BDC (ab-) Tj EMC 0 -14 Td (cd) Tj ET");
        var report = TextReplacer.ReplaceAll(session, "a", "X");
        Assert.Equal(1, report.Replaced);
        Assert.Equal("Xb-\ncd", Page(session, 0));
    }

    [Theory]
    [InlineData("hi hi", "hi")]
    [InlineData("ff", "f")]
    public void FindGivesOneMatchPerRangeEvenWhenTheTextHasSeveralHits(string text, string query)
    {
        var session = Open($"BT /F1 12 Tf 50 700 Td /Span <</ActualText ({text})>> BDC ({text}) Tj EMC ET");
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = TextSearch.Find(TextPage.Create(document, document.Pages[0]), query);
        Assert.Single(found);
        Assert.Equal(2, TextReplacer.ReplaceAll(session, query, "g").Replaced);
    }

    [Fact]
    public void AHitThatRunsIntoASpanDoesNotHideTheNextHitInIt()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (say hello wor)>> BDC (say hello wor) Tj EMC " +
            "/Span <</ActualText (ld, world again)>> BDC (ld, world again) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "world", "globe");
        Assert.Equal(2, report.Replaced);
        Assert.Equal("say hello globe, globe again", Page(session, 0));
    }

    [Fact]
    public void TwoHitsOnOneFoldedLetterReplaceItOnce()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (Stra\\337e ist)>> BDC (Strasse ist) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "s", "x", new TextSearchOptions(FoldDiacritics: true));
        Assert.Equal(3, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal("xtraxe ixt", Page(session, 0));
    }

    [Theory]
    [InlineData("o\\001ce", "f", "ph", "ophphice", 2)]
    [InlineData("o\\001ce", "i", "x", "offxce", 1)]
    [InlineData("\\003nd", "i", "y", "fynd", 1)]
    [InlineData("\\003nd", "fi", "g", "gnd", 1)]
    [InlineData("a\\002b", "f", "x", "axxb", 2)]
    [InlineData("a\\002b", "ff", "x", "axb", 1)]
    public void ALigatureGlyphKeepsItsOtherLettersWhenPartOfItIsReplaced(string shown, string query, string replacement, string expected, int count)
    {
        var session = Open($"BT /F4 12 Tf 50 700 Td ({shown}) Tj ET");
        var report = TextReplacer.ReplaceAll(session, query, replacement);
        Assert.Equal(count, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal(expected, Page(session, 0));
    }

    [Fact]
    public void AHitThatEndsOnALineBreakDoesNotTakeTheNextHitInTheFirstCharOfTheNextLine()
    {
        var session = Open("BT /F1 12 Tf 50 700 Td (ab) Tj 0 -14 Td /Span <</ActualText (cd ab)>> BDC (cd ab) Tj EMC ET");
        var report = TextReplacer.ReplaceAll(session, "b ?", "Z", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal(EditingText.CrossesLines, Assert.Single(report.Failed).Reason);
        Assert.Equal("ab\ncd aZ", Page(session, 0));
    }

    [Theory]
    [InlineData("BT /F1 12 Tf 50 700 Td (well-) Tj 0 -14 Td (known fact) Tj ET", "\\s", "_", "well-\nknown_fact")]
    [InlineData("BT /F1 12 Tf 50 700 Td (well-) Tj 0 -14 Td (known fact) Tj ET", "\\s+", "_", "well-\nknown_fact")]
    [InlineData("BT /F1 12 Tf 50 700 Td (well-) Tj /F4 12 Tf 0 -14 Td (a\\003 b) Tj ET", "fi\\s", "Z", "well-\naZb")]
    public void AHitIsReplacedOnceOnAPageWithAJoinedLineEndHyphen(string content, string query, string replacement, string expected)
    {
        var session = Open(content);
        var report = TextReplacer.ReplaceAll(session, query, replacement, new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Empty(report.Failed);
        Assert.Equal(expected, Page(session, 0));
    }

    [Theory]
    [InlineData("(caf\\004)", "cafe", "tea", true, "tea")]
    [InlineData("(x\\005y)", "a", "b", false, "xby")]
    public void AMarkAfterTheLastLetterOfAHitIsReplacedWithIt(string shown, string query, string replacement, bool foldAccents, string expected)
    {
        var session = Open($"BT /F4 12 Tf 50 700 Td {shown} Tj ET");
        var report = TextReplacer.ReplaceAll(session, query, replacement, new TextSearchOptions(FoldDiacritics: foldAccents));
        Assert.Equal(1, report.Replaced);
        Assert.Equal(expected, Page(session, 0));
    }
}
