using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactValueTests
{
    private static PdfDocument Blank() => RedactionKit.Page("BT /F1 12 Tf 100 700 Td (page text) Tj ET");

    private static PdfAnnotation Note(PdfDocument document, string contents) =>
        new PdfAnnotationWriter(document).AddNote(document.Pages[0], new PdfRect(400, 100, 420, 120), new AnnotationInfo("Reviewer", contents));

    [Fact]
    public void CommentTextIsFoundAndRewrittenWithTheRestKept()
    {
        using var document = Blank();
        Note(document, "Mail jane.doe@example.com before friday");
        var found = RedactionFinder.FindInValues(document, RedactionKind.Email);
        var hit = Assert.Single(found);
        Assert.Equal("jane.doe@example.com", hit.Text);
        Assert.Equal(RedactionValueSource.Comment, hit.Source);

        var result = new PdfRedactor(document).Apply([], null, found);
        using var output = RedactionKit.Open(result);
        Assert.Equal("Mail  before friday", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
        Assert.False(RedactionKit.Holds(result.Bytes, "jane.doe@example.com"));
        Assert.True(result.Verification.IsClean);
        Assert.Equal(1, Assert.Single(result.Report.Pages).Values);
        Assert.False(result.Report.Pages[0].IsEmpty);
    }

    [Fact]
    public void OverlappingHitsFromTwoFindersAreRewrittenAsTheirUnion()
    {
        using var document = Blank();
        Note(document, "Mail jane.doe@example.com before friday");
        var found = RedactionFinder.FindInValues(document, RedactionKind.Email).Concat(RedactionFinder.FindWordsInValues(document, ["doe"])).ToList();
        Assert.Equal(2, found.Count);
        var result = new PdfRedactor(document).Apply([], null, found);
        using var output = RedactionKit.Open(result);
        Assert.Equal("Mail  before friday", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
        Assert.False(RedactionKit.Holds(result.Bytes, "example.com"));
    }

    [Fact]
    public void OverlayTextReplacesTheMatch()
    {
        using var document = Blank();
        Note(document, "call 555-0147-9988 now");
        var found = RedactionFinder.FindWordsInValues(document, ["555-0147-9988"]);
        var result = new PdfRedactor(document).Apply([], new RedactionOptions { OverlayText = "[x]" }, found);
        using var output = RedactionKit.Open(result);
        Assert.Equal("call [x] now", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
    }

    [Fact]
    public void RichTextAndTheSubjectLoseTheWordsToo()
    {
        using var document = Blank();
        var note = Note(document, "the secret plan");
        note.Dictionary["RC"] = PdfText.ToObject("<body><p>the secret plan</p></body>");
        note.Dictionary["Subj"] = PdfText.ToObject("secret");
        var found = RedactionFinder.FindWordsInValues(document, ["secret"]);
        var result = new PdfRedactor(document).Apply([], null, found);
        Assert.False(RedactionKit.Holds(result.Bytes, "secret"));
        Assert.True(result.Verification.IsClean);
    }

    [Fact]
    public void FreeTextIsDrawnAgainWithoutTheMatch()
    {
        using var document = Blank();
        new PdfAnnotationWriter(document).AddFreeText(document.Pages[0], new PdfRect(100, 400, 300, 440), "pay IBAN DE89 3704 0044 0532 0130 00 today", null, null, new AnnotationInfo("A"), null);
        var found = RedactionFinder.FindInValues(document, RedactionKind.Iban);
        var hit = Assert.Single(found);
        Assert.Equal("DE89 3704 0044 0532 0130 00", hit.Text);
        var result = new PdfRedactor(document).Apply([], null, found);
        using var output = RedactionKit.Open(result);
        var left = Assert.Single(PdfAnnotations.Read(output, output.Pages[0]));
        Assert.Equal("pay IBAN  today", left.Contents);
        Assert.False(RedactionKit.Holds(result.Bytes, "0532 0130"));
        Assert.True(result.Verification.IsClean);
    }

    [Fact]
    public void RemovedFreeTextDoesNotHideALaterHitOnThePage()
    {
        using var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        writer.AddFreeText(document.Pages[0], new PdfRect(100, 400, 300, 440), "secret", null, null, new AnnotationInfo("A"), null);
        Note(document, "mail jane.doe@example.com");
        var found = RedactionFinder.FindWordsInValues(document, ["secret", "jane.doe@example.com"]);
        Assert.Equal(2, found.Count);
        var result = new PdfRedactor(document).Apply([], new RedactionOptions { OverlayText = "😀" }, found);
        Assert.False(RedactionKit.Holds(result.Bytes, "jane.doe@example.com"));
        Assert.True(result.Verification.IsClean);
    }

    [Fact]
    public void FieldValueIsRewrittenAndItsAppearanceDrawnAgain()
    {
        using var document = Blank();
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "note", 0, new PdfRect(100, 490, 400, 510)) { Value = "ssn 123-45-6789 on file" });
        var found = RedactionFinder.FindInValues(document, RedactionKind.UsSocialSecurity);
        var hit = Assert.Single(found);
        Assert.Equal(RedactionValueSource.Field, hit.Source);

        var result = new PdfRedactor(document).Apply([], null, found);
        using var output = RedactionKit.Open(result);
        var field = Assert.Single(PdfForm.Read(output).Fields);
        Assert.Equal("ssn  on file", field.Value);
        Assert.False(RedactionKit.Holds(result.Bytes, "123-45-6789"));
        Assert.True(result.Verification.IsClean);
        Assert.Equal(1, Assert.Single(result.Report.Pages).Values);
    }

    [Fact]
    public void ValueChangedSinceTheSearchIsLeftAlone()
    {
        using var document = Blank();
        Note(document, "abc secret def");
        var found = RedactionFinder.FindWordsInValues(document, ["secret"]);
        var stale = found.Select(f => f with { Start = f.Start + 1 }).ToList();
        var result = new PdfRedactor(document).Apply([], null, stale);
        using var output = RedactionKit.Open(result);
        Assert.Equal("abc secret def", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
        Assert.Empty(result.Report.Pages);
    }

    [Fact]
    public void RegexAndWholeWordSearchSeveralHitsInOneValue()
    {
        using var document = Blank();
        Note(document, "cat concat cat");
        Assert.Equal(2, RedactionFinder.FindWordsInValues(document, ["cat"]).Count);
        Assert.Equal(3, RedactionFinder.FindWordsInValues(document, ["cat"], wholeWord: false).Count);
        var found = RedactionFinder.FindRegexInValues(document, "c[a]t");
        var result = new PdfRedactor(document).Apply([], null, found);
        using var output = RedactionKit.Open(result);
        Assert.Equal(" con ", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
    }

    [Fact]
    public void ValuesAndMarksWorkTogether()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        Note(document, "secret note");
        var marks = RedactionKit.MarksOf(document, 0, "secret words");
        var found = RedactionFinder.FindWordsInValues(document, ["secret"]);
        var result = new PdfRedactor(document).Apply(marks, null, found);
        Assert.False(RedactionKit.Holds(result.Bytes, "secret note"));
        Assert.True(result.Verification.IsClean);
        using var output = RedactionKit.Open(result);
        Assert.Equal(" note", Assert.Single(PdfAnnotations.Read(output, output.Pages[0])).Contents);
    }
}
