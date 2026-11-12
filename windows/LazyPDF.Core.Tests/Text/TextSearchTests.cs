using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextSearchTests
{
    private static IReadOnlyList<SearchMatch> Find(TextPage page, string query, TextSearchOptions? options = null) =>
        TextSearch.Find(page, query, options);

    private static TextPage Sample() =>
        Text(Line(100, 700, "The quick Brown fox") + Line(100, 688, "jumps over the lazy dog") + Line(100, 676, "The end"));

    [Fact]
    public void PlainSearchIgnoresCaseAndGivesQuads()
    {
        var hits = Find(Sample(), "the");
        Assert.Equal(3, hits.Count);
        Assert.Equal("The", hits[0].Text);
        Assert.Equal(new TextRange(0, 3), hits[0].Range);
        var quad = Assert.Single(hits[0].Quads);
        Assert.Equal(100, quad.Bounds.Left, 6);
        Assert.Equal(115, quad.Bounds.Right, 6);
        Assert.Equal(0, hits[0].Page);
    }

    [Fact]
    public void MatchCaseTakesOnlyTheSameCase()
    {
        var page = Sample();
        Assert.Equal(2, Find(page, "The", new TextSearchOptions(MatchCase: true)).Count);
        Assert.Single(Find(page, "Brown", new TextSearchOptions(MatchCase: true)));
        Assert.Empty(Find(page, "brown", new TextSearchOptions(MatchCase: true)));
    }

    [Fact]
    public void WholeWordRefusesWordParts()
    {
        var page = Sample();
        Assert.Equal(3, Find(page, "the").Count);
        Assert.Empty(Find(page, "ov", new TextSearchOptions(WholeWord: true)));
        Assert.Single(Find(page, "over", new TextSearchOptions(WholeWord: true)));
        Assert.Equal(3, Find(page, "the", new TextSearchOptions(WholeWord: true)).Count);
    }

    [Fact]
    public void AMatchCanRunOverALineBreak()
    {
        var hits = Find(Sample(), "fox jumps");
        var hit = Assert.Single(hits);
        Assert.Equal(2, hit.Quads.Count);
        Assert.Equal("fox\njumps", hit.Text);
    }

    [Fact]
    public void AnyWhiteSpaceInTheQueryMatchesAnyGap()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td [(a) -800 (b)] TJ ET");
        Assert.Single(Find(page, "a   b"));
        Assert.Single(Find(page, "a b"));
    }

    [Fact]
    public void AHyphenAtALineEndIsPartOfTheMatchOrNot()
    {
        var page = Text(Line(100, 700, "some informa-") + Line(100, 688, "tion and a well-") + Line(100, 676, "known case"));
        var split = Find(page, "information");
        Assert.Equal(2, Assert.Single(split).Quads.Count);
        Assert.Equal("information", split[0].Text.Replace("\n", ""));
        Assert.Single(Find(page, "well-known"));
        Assert.Single(Find(page, "informa-tion"));
    }

    [Fact]
    public void ASoftHyphenAtALineEndJoinsToo()
    {
        var page = Text(Line(100, 700, @"some informa\001") + Line(100, 688, "tion here"), "", (1, "\u00AD"));
        Assert.Single(Find(page, "information"));
    }

    [Fact]
    public void RegexSearchWorksOnTheTextOfThePage()
    {
        var page = Sample();
        var hits = Find(page, @"\b[qj]\w+", new TextSearchOptions(Regex: true));
        Assert.Equal(["quick", "jumps"], hits.Select(h => h.Text));
        Assert.Single(Find(page, @"Brown\s+fox", new TextSearchOptions(Regex: true, MatchCase: true)));
        Assert.Single(Find(page, @"fox\sjumps", new TextSearchOptions(Regex: true)));
        Assert.Empty(Find(page, @"x*", new TextSearchOptions(Regex: true, WholeWord: true)));
    }

    [Fact]
    public void ABadPatternThrowsArgumentException()
    {
        Assert.ThrowsAny<ArgumentException>(() => Find(Sample(), "(", new TextSearchOptions(Regex: true)));
    }

    [Fact]
    public void AnEmptyQueryFindsNothing()
    {
        Assert.Empty(Find(Sample(), ""));
        Assert.Empty(Find(Sample(), "   "));
    }

    [Fact]
    public void FoldingIgnoresDiacritics()
    {
        var page = Text(Line(100, 700, @"caf\001 na\002ve r\003sum\001"), "", (1, "\u00E9"), (2, "\u00EF"), (3, "\u00E9"));
        Assert.Empty(Find(page, "cafe"));
        var fold = new TextSearchOptions(FoldDiacritics: true);
        Assert.Single(Find(page, "cafe", fold));
        Assert.Single(Find(page, "naive", fold));
        Assert.Equal(2, Find(page, "r\u00E9sum\u00E9", fold).Count + Find(page, "resume", fold).Count);
        Assert.Single(Find(page, "caf\u00E9"));
    }

    [Fact]
    public void FoldingMatchesLettersFromCombiningMarks()
    {
        var page = Text(Line(100, 700, @"cafe\001"), "", (1, "\u0301"));
        Assert.Single(Find(page, "cafe", new TextSearchOptions(FoldDiacritics: true)));
    }

    [Fact]
    public void DottedAndDotlessIAreDifferentUntilFolded()
    {
        var page = Text(Line(100, 700, @"\001stanbul \002\003\002k \004zmir"), "", (1, "\u0130"), (2, "\u0131"), (3, "\u015F"), (4, "I"));
        Assert.Single(Find(page, "\u0130stanbul"));
        Assert.Single(Find(page, "istanbul"));
        Assert.Single(Find(page, "Istanbul"));
        Assert.Single(Find(page, "\u0131\u015F\u0131k"));
        Assert.Empty(Find(page, "isik"));
        Assert.Single(Find(page, "izmir"));
        Assert.Empty(Find(page, "\u0131zmir"));

        var fold = new TextSearchOptions(FoldDiacritics: true);
        Assert.Single(Find(page, "istanbul", fold));
        Assert.Single(Find(page, "\u0130STANBUL", fold));
        Assert.Single(Find(page, "isik", fold));
        Assert.Single(Find(page, "ISIK", fold));
        Assert.Single(Find(page, "\u0131zmir", fold));
        Assert.Single(Find(page, "izmir", fold));
    }

    [Fact]
    public void MatchesDoNotOverlap()
    {
        var page = Text(Line(100, 700, "aaaa"));
        Assert.Equal(2, Find(page, "aa").Count);
    }

    [Fact]
    public void ASearchOverAnImpliedSpaceWorks()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td [(one) -700 (two)] TJ ET");
        Assert.Single(Find(page, "one two"));
    }

    [Fact]
    public void ADocumentSearchStreamsPageByPageAndCanBeCancelled()
    {
        var doc = ThreePages();
        var results = TextSearch.Find(new TextCache(doc), "page").ToList();
        Assert.Equal([0, 1, 2], results.Select(r => r.Page));

        var some = TextSearch.Find(new TextCache(doc), "page", first: 1, last: 1).ToList();
        Assert.Equal([1], some.Select(r => r.Page));

        using var source = new CancellationTokenSource();
        using var enumerator = TextSearch.Find(new TextCache(doc), "page", cancel: source.Token).GetEnumerator();
        Assert.True(enumerator.MoveNext());
        Assert.Equal(0, enumerator.Current.Page);
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => enumerator.MoveNext());
    }

    [Fact]
    public void ARegexThatNeverEndsGivesNoHitsForThePage()
    {
        var page = Text(Line(100, 700, string.Concat(Enumerable.Repeat("a", 40)) + "!"));
        var hits = Find(page, @"^(a+)+$", new TextSearchOptions(Regex: true));
        Assert.Empty(hits);
    }

    [Fact]
    public void ATimedOutPageIsReported()
    {
        var page = Text(Line(100, 700, string.Concat(Enumerable.Repeat("a", 40)) + "!"));
        var timeouts = new SearchTimeouts();
        Assert.Empty(TextSearch.Find(page, @"^(a+)+$", new TextSearchOptions(Regex: true), timeouts: timeouts));
        Assert.Equal([0], timeouts.Pages);
        var quiet = new SearchTimeouts();
        Assert.Single(TextSearch.Find(page, "a+!", new TextSearchOptions(Regex: true), timeouts: quiet));
        Assert.Empty(quiet.Pages);
    }

    private static PdfDocument ThreePages()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 600 800]>>");
        for (int i = 0; i < 3; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {6 + i} 0 R /Resources <</Font <</F1 9 0 R>>>>>>");
        for (int i = 0; i < 3; i++) pdf.Stream(6 + i, "", Line(100, 700, $"on page number {i}"));
        TextTestPdf.Font(pdf, 9);
        return PdfDocument.Open(pdf.Finish());
    }
}
