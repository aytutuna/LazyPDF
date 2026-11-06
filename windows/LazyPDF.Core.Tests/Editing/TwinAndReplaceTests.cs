using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Text drawn twice at one place, regex replacement and edits taken back.
public class TwinAndReplaceTests
{
    private sealed class Probe(List<(string Text, int Mode, double X)> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) =>
            found.Add((glyph.Unicode ?? "", context.State.RenderMode, Math.Round(glyph.Matrix.E, 2)));
    }

    private static List<(string Text, int Mode, double X)> Read(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = new List<(string, int, double)>();
        new ContentInterpreter(document).Run(document.Pages[0], new Probe(found));
        return found;
    }

    private static string Page(PdfEditSession session) => EditKit.Text(session).Trim();

    [Fact]
    public void ATwinInAnotherFontGetsTheCodesOfItsOwnFont()
    {
        const string Swapped = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /B 66 /A]>>>>";
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (AB) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (BA) Tj ET",
            more: pdf => pdf.Obj(7, Swapped), resources: "/Font <</F1 5 0 R /F3 7 0 R>>");
        var editor = new PageEditor(session, 0);
        var result = editor.ReplaceText(EditKit.Find(session, "AB"), "BA");
        Assert.True(result.Done, result.Problem);
        var shown = Read(session);
        Assert.Equal("BA", string.Concat(shown.Where(g => g.Mode == 0).Select(g => g.Text)));
        Assert.Equal("BA", string.Concat(shown.Where(g => g.Mode == 3).Select(g => g.Text)));
    }

    [Fact]
    public void ATwinInAnotherFormKeepsItsOwnStandInFont()
    {
        string form = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>";
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (ab) Tj ET /Fm0 Do",
            more: pdf => pdf.Stream(7, form, "BT /F1 12 Tf 3 Tr 50 700 Td (ab) Tj ET"),
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>>");
        var editor = new PageEditor(session, 0, new EditArialSource());
        var result = editor.ReplaceText(EditKit.Find(session, "ab"), "ğş");
        Assert.True(result.Done, result.Problem);
        var document = PdfDocument.Open(session.Current.ToArray());
        var form0 = document.Resolve(document.Dict(document.Pages[0].Resources, "XObject")?["Fm0"]) as PdfStream;
        var fonts = document.Dict(document.Dict(form0!.Dictionary, "Resources"), "Font")!;
        string content = System.Text.Encoding.Latin1.GetString(document.Data(form0));
        foreach (var name in System.Text.RegularExpressions.Regex.Matches(content, @"/(LzE\d+) ").Select(m => m.Groups[1].Value)) Assert.NotNull(fonts[name]);
        Assert.Contains("/LzE", content);
    }

    [Fact]
    public void ALookbehindIsSeenInTheTextOfThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Total 42 and 17) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(?<=Total )\d+", "99", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("Total 99 and 17", Page(session));
    }

    [Fact]
    public void AGroupOfAFoldedMatchKeepsTheAccentsOfThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (A café here) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(cafe) here", "<$1>", new TextSearchOptions(Regex: true, FoldDiacritics: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("A <café>", Page(session));
    }

    [Fact]
    public void EveryWordOfAFoldedSearchKeepsItsAccents()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (A café here) Tj ET");
        TextReplacer.ReplaceAll(session, @"(\w+)", "<$1>", new TextSearchOptions(Regex: true, FoldDiacritics: true));
        Assert.Equal("<A> <café> <here>", Page(session));
    }

    [Fact]
    public void AMatchThatExistsOnlyOnTheFoldedTextIsExpandedWithItsGroup()
    {
        const string Dotted = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [73 /Idotaccent]>>>>";
        var session = EditKit.Session("BT /F3 12 Tf 50 700 Td (ZMIR) Tj ET", more: pdf => pdf.Obj(7, Dotted), resources: "/Font <</F1 5 0 R /F3 7 0 R>>");
        Assert.Equal("ZMİR", Page(session));
        var report = TextReplacer.ReplaceAll(session, "(zmi)r", "<$1>", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("<ZMİ>", Page(session));
    }

    [Fact]
    public void ADollarInAGroupOfThePageIsWrittenAsItIs()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (cost $5 now) Tj ET");
        TextReplacer.ReplaceAll(session, @"(\$\d)", "[$1]$$", new TextSearchOptions(Regex: true));
        Assert.Equal("cost [$5]$ now", Page(session));
    }

    [Fact]
    public void AStandInOfATakenBackMatchIsNotReported()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (a) Tj /F1 20 Tf (b) Tj ET");
        var document = session.Document;
        var model = PageModel.Load(document, 0);
        var batch = new EditBatch(document, model.Page, model.Scan);
        var fonts = new EditArialSource();
        var builder = new TextBuilder(document, batch, fonts);
        var editor = new TextEditor(model, batch, builder, fonts);
        var mark = batch.Save();
        Assert.Throws<EditConflictException>(() => editor.Replace(EditKit.Find(session, "ab"), "ğ中"));
        batch.Restore(mark);
        Assert.Empty(builder.Substitutions);
    }

    [Fact]
    public void ARegexGroupKeepsTheCaseOfThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET");
        TextReplacer.ReplaceAll(session, @"(w\w+)", "[$1]", new TextSearchOptions(Regex: true));
        Assert.Equal("Hello [World]", Page(session));
    }

    [Fact]
    public void AStandInOfATakenBackEditIsNotUsedByTheNextOne()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (a) Tj /F1 20 Tf (b) Tj ET BT /F1 12 Tf 50 600 Td (c) Tj ET");
        var document = session.Document;
        var model = PageModel.Load(document, 0);
        var batch = new EditBatch(document, model.Page, model.Scan);
        var fonts = new EditArialSource();
        var builder = new TextBuilder(document, batch, fonts);
        var editor = new TextEditor(model, batch, builder, fonts);
        int objects = document.ObjectNumbers.Count;

        var mark = batch.Save();
        Assert.Throws<EditConflictException>(() => editor.Replace(EditKit.Find(session, "ab"), "ğ中"));
        batch.Restore(mark);
        Assert.Equal(objects, document.ObjectNumbers.Count);

        editor.Replace(EditKit.Find(session, "c"), "ğ");
        batch.Apply();
        builder.WriteAdditions();
        session.Commit("test");
        var reopened = PdfDocument.Open(session.Current.ToArray());
        string content = System.Text.Encoding.Latin1.GetString(reopened.Pages[0].Contents());
        var names = System.Text.RegularExpressions.Regex.Matches(content, @"/(LzE\d+) ").Select(m => m.Groups[1].Value).ToList();
        Assert.NotEmpty(names);
        var font = reopened.Dict(reopened.Pages[0].Resources, "Font")!;
        Assert.All(names, n => Assert.NotNull(font[n]));
    }

    [Fact]
    public void AFailedEditLeavesNoObjectsBehind()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (abc) Tj ET");
        int before = session.Document.ObjectNumbers.Count;
        var result = new PageEditor(session, 0, new EditArialSource()).AddTextBox(new PdfRect(100, 300, 300, 400), "中文");
        Assert.False(result.Done);
        Assert.Equal(before, session.Document.ObjectNumbers.Count);
    }

    private const string TwoPlace = "BT /F1 12 Tf 14 TL 50 700 Td (Hello) Tj 40 0 Td (World) Tj -40 -14 Td (a much longer second line here) Tj ET";

    [Fact]
    public void RightAlignMovesEveryPositionedRunOfALine()
    {
        var session = EditKit.Session(TwoPlace);
        var editor = new PageEditor(session, 0);
        var before = Read(session);
        Assert.True(editor.SetAlignment(editor.Objects.OfType<TextObject>().Single(), TextAlignment.Right).Done);
        var after = Read(session);
        Assert.Equal(before.Count, after.Count);
        double shift = after[0].X - before[0].X;
        Assert.True(shift > 20);
        for (int i = 0; i < 10; i++) Assert.Equal(before[i].X + shift, after[i].X, 1);
    }

    [Fact]
    public void AlignMovesADoubleStruckLineTogether()
    {
        string content = "BT /F1 12 Tf 14 TL 50 700 Td (Hello) Tj ET BT /F1 12 Tf 50.2 700 Td (Hello) Tj ET BT /F1 12 Tf 50 686 Td (a much longer second line here) Tj ET";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var block = editor.Objects.OfType<TextObject>().Single();
        var before = Read(session);
        Assert.True(editor.SetAlignment(block, TextAlignment.Right).Done);
        var after = Read(session);
        Assert.Equal(after[0].X - before[0].X, after[5].X - before[5].X, 2);
        Assert.True(after[0].X - before[0].X > 20);
    }

    [Fact]
    public void TheTailOfAHiddenCopyThatCannotShowTheNewLettersStaysWhereItWas()
    {
        string cut = $"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 68 /Widths [{string.Join(" ", Enumerable.Repeat(600, 37))}] /Encoding /WinAnsiEncoding>>";
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (AB CD) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB CD) Tj ET",
            more: pdf => pdf.Obj(7, cut), resources: "/Font <</F1 5 0 R /F3 7 0 R>>");
        var tail = Read(session).Where(g => g.Mode == 3 && g.Text is "C" or "D").ToList();
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "AB"), "XY");
        Assert.True(result.Done, result.Problem);
        Assert.Equal(tail, Read(session).Where(g => g.Mode == 3 && g.Text is "C" or "D").ToList());
    }

    [Fact]
    public void TheWholeMatchOfARegexIsTheCaseOfThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"H\w+", "[$&]", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("[Hello] World", Page(session));
    }

    [Fact]
    public void TheTextAroundAMatchAndTheLastGroupComeFromThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Ab Cd!) Tj ET");
        TextReplacer.ReplaceAll(session, @"(c)d", "<$`|$'|$+>", new TextSearchOptions(Regex: true));
        Assert.Equal("Ab <Ab |!|C>!", Page(session));
    }

    [Fact]
    public void ADollarEscapeIsNotTakenForTheStartOfAGroup()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (cost 42 now) Tj ET");
        TextReplacer.ReplaceAll(session, @"(\d+)", "$$1", new TextSearchOptions(Regex: true));
        Assert.Equal("cost $1 now", Page(session));
        session = EditKit.Session("BT /F1 12 Tf 50 700 Td (cost 42 now) Tj ET");
        TextReplacer.ReplaceAll(session, @"\d+", "$$0.99", new TextSearchOptions(Regex: true));
        Assert.Equal("cost $0.99 now", Page(session));
    }

    [Fact]
    public void TheSpacesAtTheEdgesOfAGroupAreKept()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (cost 42 USD now) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(\d+)( USD)", "$1$2!", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("cost 42 USD! now", Page(session));
        session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET");
        TextReplacer.ReplaceAll(session, @"(\w+)( )(\w+)", "$3$2$1", new TextSearchOptions(Regex: true));
        Assert.Equal("World Hello", Page(session));
    }

    [Fact]
    public void TheWholeInputOfARegexIsThePageToo()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello World) Tj ET");
        TextReplacer.ReplaceAll(session, @"H\w+", "[$_]", new TextSearchOptions(Regex: true));
        Assert.Equal("[Hello World] World", Page(session));
    }

    [Fact]
    public void AGroupWrittenWithALeadingZeroIsTheGroupOfThePageEvenWithNamedGroups()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (HELLO) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(?<y>h)(\w+)", "$01", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("ELLO", Page(session));
    }

    [Fact]
    public void ANumberedGroupThatIsNamedKeepsTheCaseOfThePage()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Invoice 42) Tj ET");
        var report = TextReplacer.ReplaceAll(session, @"(?<word>[a-z]+) (\d+)", "$2 #$1", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("Invoice #42", Page(session));
        session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Invoice 42) Tj ET");
        TextReplacer.ReplaceAll(session, @"(?<word>[a-z]+) (\d+)", "$+!", new TextSearchOptions(Regex: true));
        Assert.Equal("Invoice!", Page(session));
        session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Invoice 42) Tj ET");
        TextReplacer.ReplaceAll(session, @"(?<word>[a-z]+) (\d+)", "${2}|${word}", new TextSearchOptions(Regex: true));
        Assert.Equal("Invoice|Invoice", Page(session));
    }

    [Fact]
    public void ADigitThatIsNotAsciiAfterAGroupNumberIsText()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (ab) Tj ET");
        var report = TextReplacer.ReplaceAll(session, "(a)b", "$1\u0663", new TextSearchOptions(Regex: true), new EditArialSource());
        Assert.Equal(1, report.Replaced);
        Assert.Equal("a\u0663", Page(session));
    }

    [Theory]
    [InlineData("$99999999999")]
    [InlineData("${99999999999}")]
    [InlineData("$4294967297")]
    public void AGroupNumberPastInt32IsRefusedAndNothingChanges(string replacement)
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (ab) Tj ET");
        Assert.ThrowsAny<ArgumentException>(() => TextReplacer.ReplaceAll(session, "(a)b", replacement, new TextSearchOptions(Regex: true)));
        Assert.False(session.CanUndo);
        Assert.Equal("ab", Page(session));
    }

    [Theory]
    [InlineData("(?x) # (\n(?<y>a)(b)")]
    [InlineData("(?#c(d)(?<y>a)(b)")]
    public void AParenthesisInACommentIsNotAGroup(string pattern)
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (ab) Tj ET");
        var report = TextReplacer.ReplaceAll(session, pattern, "$1|$2|$+", new TextSearchOptions(Regex: true));
        Assert.Equal(1, report.Replaced);
        Assert.Equal("b|a|a", Page(session));
    }

    [Fact]
    public void TheTailOfAHiddenCopyFollowsTheNewTextWhenItIsWiderThanTheOldOne()
    {
        string cut = $"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 68 /Widths [278 {string.Join(" ", Enumerable.Repeat(600, 32))} 667 667 722 722] /Encoding /WinAnsiEncoding>>";
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (AB CD) Tj ET BT /F3 12 Tf 3 Tr 50 700 Td (AB CD) Tj ET",
            more: pdf => pdf.Obj(7, cut), resources: "/Font <</F1 5 0 R /F3 7 0 R>>");
        double Gap(List<(string Text, int Mode, double X)> shown, string letter) =>
            shown.Single(g => g.Mode == 3 && g.Text == letter).X - shown.Single(g => g.Mode == 0 && g.Text == letter).X;
        Assert.Equal(0, Gap(Read(session), "C"), 2);
        string text = Page(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "AB"), "WWWW");
        Assert.True(result.Done, result.Problem);
        var after = Read(session);
        Assert.Equal(0, Gap(after, "C"), 2);
        Assert.Equal(0, Gap(after, "D"), 2);
        Assert.Equal(text.Replace("AB", "WWWW"), Page(session));
    }
}
