using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The rows of the accessibility check and the fixes they offer, against Core's checker.
public sealed class AccessibilityRowsTests
{
    private static List<CheckRow> Rows(PdfDocument document, string fileName = "Notes.pdf") =>
        AccessibilityChecker.Check(document).Items
            .Select(i => new CheckRow(i, i.Rule == AccessibilityRule.Title ? AccessibilityEdits.TitleOf(document, fileName) : i.Rule == AccessibilityRule.Language ? AccessibilityEdits.LanguageOf(document) : ""))
            .ToList();

    private static CheckRow Row(IEnumerable<CheckRow> rows, AccessibilityRule rule) => rows.First(r => r.Name == AccessibilityText.Name(rule));

    [Fact]
    public void AnUntaggedFileFailsTheTagCheckAndOffersToAddTags()
    {
        var document = PdfDocument.Open(Pdfs.Text());

        var row = Row(Rows(document), AccessibilityRule.Tagged);

        Assert.Equal("Failed", row.Level);
        Assert.Equal(RowAction.AddTags, row.Action);
        Assert.Equal("Add tags", row.ActionText);
    }

    [Fact]
    public void ColourContrastIsLeftToAPersonWithNoButton()
    {
        var row = Row(Rows(PdfDocument.Open(Pdfs.Text())), AccessibilityRule.Contrast);

        Assert.Equal("Needs a person", row.Status);
        Assert.Equal(RowAction.None, row.Action);
    }

    [Fact]
    public void TheTitleBoxStartsWithTheFileNameAndSavingItFixesTheCheck()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var row = Row(Rows(document, "Lease agreement.pdf"), AccessibilityRule.Title);
        Assert.Equal("Failed", row.Level);
        Assert.Equal("Lease agreement", row.Value);

        row.Value = "Lease for the flat";
        Assert.True(AccessibilityEdits.Apply(document, row.Editor, row.Action, row.Value.Trim()));

        var after = AccessibilityChecker.Check(PdfDocument.Open(document.SaveIncremental()))[AccessibilityRule.Title];
        Assert.Equal(AccessibilityStatus.Passed, after.Status);
        Assert.Equal("Lease for the flat", DocumentMetadata.Read(document).Title);
    }

    [Fact]
    public void AnEmptyTitleChangesNothing()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var row = Row(Rows(document), AccessibilityRule.Title);
        row.Value = "  ";

        Assert.False(AccessibilityEdits.Apply(document, row.Editor, row.Action, row.Value.Trim()));
    }

    [Fact]
    public void TheLanguageIsSetFromItsBoxAndABadTagIsRefused()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var row = Row(Rows(document), AccessibilityRule.Language);

        Assert.Throws<ArgumentException>(() => AccessibilityEdits.Apply(document, row.Editor, row.Action, "not a tag!"));

        Assert.True(AccessibilityEdits.Apply(document, row.Editor, row.Action, "tr-TR"));
        Assert.Equal("tr-TR", AccessibilityEdits.LanguageOf(document));
    }

    [Fact]
    public void AnEditOfTheBoxAfterTheCaptureIsNotWritten()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var row = Row(Rows(document), AccessibilityRule.Title);
        row.Value = "Lease for the flat";
        string captured = row.Value.Trim();

        row.Value = "Something typed later";
        Assert.True(AccessibilityEdits.Apply(document, row.Editor, row.Action, captured));

        Assert.Equal("Lease for the flat", DocumentMetadata.Read(document).Title);
    }

    [Fact]
    public Task ASignedFileIsNotChangedUntilTheNoticeIsAnswered() => Sta.Run(async () =>
    {
        var host = new RecordingHost();
        using var tab = new DocumentTab(PdfEditSession.Open(StampsPanelTests.Signed(false)), new FakeRenderer(), null, "a.pdf");
        var row = Row(Rows(tab.Document), AccessibilityRule.Title);
        row.Value = "First";
        string captured = row.Value.Trim();

        await ChangeGate.RunAsync(tab, host, "Title", () =>
        {
            AccessibilityEdits.Apply(tab.Document, row.Editor, row.Action, captured);
            return Task.CompletedTask;
        });
        row.Value = "Typed while the notice was up";

        Assert.Equal(["Check before going on"], host.Notices);
        Assert.NotEqual("First", DocumentMetadata.Read(tab.Document).Title);
        host.Actions.Single()!.Run();
        await Sta.Until(() => DocumentMetadata.Read(tab.Document).Title == "First");
    });

    [Fact]
    public async Task ASavedFixIsOneUndoStepOnTheTab()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        var row = Row(Rows(tab.Document), AccessibilityRule.Language);
        row.Value = "en-GB";

        Assert.True(AccessibilityEdits.Apply(tab.Document, row.Editor, row.Action, row.Value.Trim()));
        Assert.True(tab.Commit("Language"));

        Assert.Equal("Language", tab.Session.UndoLabel);
        tab.Undo();
        Assert.Equal("", PdfText.Read(tab.Document, tab.Document.Catalog, "Lang") ?? "");
    }

[Fact]
    public void AddTagsIsOnlyOfferedWhereTheTaggerWillTakeTheFile()
    {
        var item = AccessibilityChecker.Check(PdfDocument.Open(Pdfs.Text()))[AccessibilityRule.Tagged];

        Assert.Equal(RowAction.AddTags, new CheckRow(item).Action);
        Assert.Equal(RowAction.AddTags, new CheckRow(item, "", canAddTags: true).Action);
        Assert.Equal(RowAction.None, new CheckRow(item, "", canAddTags: false).Action);
    }

    [Fact]
    public void ATaggedMarkWithoutATreeIsNotSomethingTheTaggerWillTake()
    {
        var plain = PdfDocument.Open(Pdfs.Text());
        Assert.True(AccessibilityEdits.CanAddTags(plain));

        var marked = PdfDocument.Open(Pdfs.Text());
        marked.Catalog["MarkInfo"] = new PdfDictionary { ["Marked"] = new PdfBoolean(true) };
        Assert.False(AccessibilityEdits.CanAddTags(marked));
        Assert.True(AutoTagger.Tag(marked).AlreadyTagged);

        var tagged = PdfDocument.Open(Pdfs.Text());
        AutoTagger.Tag(tagged);
        Assert.False(AccessibilityEdits.CanAddTags(tagged));
    }

    [Fact]
    public void AnEditedBoxIsToldFromOneThatOnlyHoldsWhatItStartedWith()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var row = Row(Rows(document, "Lease agreement.pdf"), AccessibilityRule.Title);
        Assert.False(row.Edited);

        row.Value = " Lease agreement ";
        Assert.False(row.Edited);

        row.Value = "Lease for the flat";
        Assert.True(row.Edited);
    }

    [Fact]
    public void ThePlaceButtonGoesToEachPageInTurn()
    {
        var item = new AccessibilityItem(AccessibilityRule.FigureAlt, "Figures", AccessibilityStatus.Failed, "Two figures.",
            [new AccessibilityPlace(2, null), new AccessibilityPlace(-1, null), new AccessibilityPlace(5, null), new AccessibilityPlace(2, null)], AccessibilityFix.None);
        var row = new CheckRow(item);

        Assert.True(row.HasPlaces);
        Assert.Equal("Go to page 3", row.PlaceText);
        Assert.Equal(2, row.NextPage());
        Assert.Equal("Go to page 6", row.PlaceText);
        Assert.Equal(5, row.NextPage());
        Assert.Equal(2, row.NextPage());
    }

    [Fact]
    public void ARowReadsAsItsNameItsStatusAndItsMessage()
    {
        var item = new AccessibilityItem(AccessibilityRule.Links, "Links have text", AccessibilityStatus.Passed, "Every link is tagged and has text.", [], AccessibilityFix.None);

        Assert.Equal("Links have text, Passed. Every link is tagged and has text.", new CheckRow(item).Summary);
    }
}
