using Xunit;

namespace LazyPDF.Core.Tests;

public class ToolChainTests
{
    [Fact]
    public void ATaggedFileIsRedactedAndItsReadingOrderLosesTheWord()
    {
        using var source = PdfDocument.Open(SignatureKit.Plain(2));
        Assert.False(AutoTagger.Tag(source).AlreadyTagged);
        byte[] tagged = source.SaveRewrite();
        Assert.Contains("Contract page 1", ReadingOrder.Export(PdfDocument.Open(tagged)));

        using var document = PdfDocument.Open(tagged);
        var result = new PdfRedactor(document, new ArialSource()).Apply([RedactionKit.MarkOf(document, 0, "Contract")]);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));

        var output = PdfDocument.Open(result.Bytes);
        Assert.NotNull(StructureTree.Read(output));
        string order = ReadingOrder.Export(output);
        Assert.DoesNotContain("Contract page 1", order);
        Assert.Contains("Contract page 2", order);
        Assert.Contains("page 1", order);
        IntegrationFiles.ReadBack(result.Bytes);
        Assert.False(RedactionKit.Holds(result.Bytes, "Contract page 1"));
    }

    [Fact]
    public void ARedactedElementLosesItsTitleToo()
    {
        using var document = PdfDocument.Open(SignatureKit.Plain(1));
        AutoTagger.Tag(document);
        var tree = StructureTree.Read(document)!;
        var element = tree.Elements.First(e => e.Kids.OfType<StructContent>().Any());
        element.Title = "Contract page 1";
        tree.Write(document);

        var result = new PdfRedactor(document, new ArialSource()).Apply([RedactionKit.MarkOf(document, 0, "Contract")]);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.False(RedactionKit.Holds(result.Bytes, "Contract page 1"));
    }

    [Fact]
    public void TaggingARedactedFileTagsWhatIsLeft()
    {
        using var source = PdfDocument.Open(SignatureKit.Plain(1));
        var result = new PdfRedactor(source, new ArialSource()).Apply([RedactionKit.MarkOf(source, 0, "Contract")]);

        using var document = PdfDocument.Open(result.Bytes);
        AutoTagger.Tag(document);
        string order = ReadingOrder.Export(document);
        Assert.Contains("page 1", order);
        Assert.DoesNotContain("Contract", order);
    }

    [Fact]
    public void ATextEditShowsUpAsOneChangeInTheComparison()
    {
        byte[] original = CompareKit.Bytes([[.. CompareKit.Page("alpha").Select(CompareKit.L)]]);
        var session = PdfEditSession.Open(original);
        var page = TextPage.Create(session.Document, session.Document.Pages[0]);
        var hit = TextSearch.Find(page, "alpha3w3").First();
        var edit = new PageEditor(session, 0).ReplaceText(hit.Range, "EDITED");
        Assert.True(edit.Done, edit.Problem);

        var result = PdfComparer.Compare(PdfDocument.Open(original), PdfDocument.Open(session.Current.ToArray()));
        var change = Assert.Single(result.Changes);
        Assert.Equal(ChangeKind.Changed, change.Kind);
        Assert.Equal("alpha3w3", change.OldText);
        Assert.Equal("EDITED", change.NewText);

        Assert.True(session.Undo());
        Assert.True(PdfComparer.Compare(PdfDocument.Open(original), PdfDocument.Open(session.Current.ToArray())).IsIdentical);
    }

    [Fact]
    public async Task ExportAfterOcrHasTheRecognisedWords()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(2));
        var result = await PdfSearchable.RunAsync(session, new FakeRecognizer(OcrKit.Words(dpi: 144)), new FakeRenderer(session.Document), new OcrOptions(Dpi: 144));
        Assert.Equal(2, result.Added);

        string text = PlainTextWriter.Make(ExportLayout.Analyze(session.Document));
        foreach (var (word, _, _, _, _) in OcrKit.WordBoxes) Assert.Contains(word, text);
        Assert.Equal(2, text.Split(OcrKit.WordBoxes[0].Text).Length - 1);
    }

    [Fact]
    public void ExportOfAScanWithoutOcrHasNoText()
    {
        string text = PlainTextWriter.Make(ExportLayout.Analyze(OcrKit.Scan(1)));
        Assert.DoesNotContain(OcrKit.WordBoxes[0].Text, text);
    }

    [Fact]
    public void LinearizedFileTakesACommitAndUndoGoesBackToIt()
    {
        byte[] linear = PdfDocument.Open(IntegrationFiles.Form(3, bookmarks: [0, 2])).SaveLinearized();
        Assert.True(PdfDocument.Open(linear).IsLinearized);
        IntegrationFiles.ReadBack(linear);

        var session = PdfEditSession.Open(linear);
        PdfForm.Read(session.Document).SetValue("f2", "after");
        Assert.True(session.Commit("Fill"));
        Assert.True(session.Current.Span[..linear.Length].SequenceEqual(linear));
        var edited = IntegrationFiles.Reopen(session);
        Assert.Equal("after", PdfForm.Read(edited).Find("f2")!.Value);
        Assert.False(edited.IsLinearized);

        PageOperations.Delete(session.Document, [1]);
        Assert.True(session.Commit("Delete"));
        Assert.Equal(2, IntegrationFiles.Reopen(session).Pages.Count);

        Assert.True(session.Undo());
        Assert.True(session.Undo());
        Assert.True(session.Current.Span.SequenceEqual(linear));
        Assert.True(PdfDocument.Open(session.Current.ToArray()).IsLinearized);
        Assert.True(session.Redo());
        Assert.Equal("after", PdfForm.Read(IntegrationFiles.Reopen(session)).Find("f2")!.Value);
    }

    [Fact]
    public void ACompactedSessionCanBeLinearizedAgain()
    {
        var session = PdfEditSession.Open(PdfDocument.Open(IntegrationFiles.Form(2)).SaveLinearized());
        PdfForm.Read(session.Document).SetValue("f1", "kept");
        session.Commit("Fill");

        byte[] again = session.Document.SaveLinearized();
        Assert.True(PdfDocument.Open(again).IsLinearized);
        Assert.Equal("kept", PdfForm.Read(PdfDocument.Open(again)).Find("f1")!.Value);
        IntegrationFiles.ReadBack(again);
    }
}
