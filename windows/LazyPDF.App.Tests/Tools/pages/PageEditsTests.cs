using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the Pages panel does to a document, against the real engine.
public sealed class PageEditsTests
{
    private static PdfDocument Open(int pages = 5) => PdfDocument.Open(Pdfs.Text(pages));

    private static string TextOf(PdfDocument document, int page) =>
        System.Text.Encoding.Latin1.GetString(document.Pages[page].Contents());

    [Theory]
    [InlineData(InsertPlace.AfterSelection, 3)]
    [InlineData(InsertPlace.BeforeSelection, 1)]
    [InlineData(InsertPlace.AtStart, 0)]
    [InlineData(InsertPlace.AtEnd, 5)]
    public void ANewPageGoesWhereTheChoiceSays(InsertPlace place, int expected)
    {
        Assert.Equal(expected, PageEdits.InsertAt(place, [1, 2], 5));
    }

    [Fact]
    public void WithNothingSelectedANewPageGoesLast()
    {
        Assert.Equal(5, PageEdits.InsertAt(InsertPlace.AfterSelection, [], 5));
        Assert.Equal(5, PageEdits.InsertAt(InsertPlace.BeforeSelection, [], 5));
    }

    [Fact]
    public void ABlankPageTakesTheSizeOfThePageBeforeIt()
    {
        var document = Open(2);
        PageOperations.SetBox(document, [0], PageBox.Crop, new PdfRect(0, 0, 300, 400));
        var (width, height) = PageEdits.NeighbourSize(document, 1);

        PageOperations.InsertBlank(document, 1, width, height);

        Assert.Equal(3, document.Pages.Count);
        var shown = new PageGeometry(document.Pages[1]);
        Assert.Equal(300, shown.Width, 1);
        Assert.Equal(400, shown.Height, 1);
    }

    [Theory]
    [InlineData(new[] { 1, 2 }, 4, new[] { 2, 3 })]
    [InlineData(new[] { 3 }, 0, new[] { 0 })]
    [InlineData(new[] { 0, 4 }, 2, new[] { 1, 2 })]
    [InlineData(new[] { 1 }, 5, new[] { 4 })]
    public void MovedPagesAreFoundWhereTheyLand(int[] pages, int before, int[] expected)
    {
        Assert.Equal(expected, PageEdits.MovedTo(pages, before));
    }

    [Fact]
    public void TheLandingPlaceMatchesWhatMoveDoes()
    {
        var document = Open(6);
        var marked = Enumerable.Range(0, 6).Select(i => TextOf(document, i)).ToList();
        int[] pages = [1, 4];

        PageOperations.Move(document, pages, 3);

        var landed = PageEdits.MovedTo(pages, 3).ToList();
        Assert.Equal(marked[1], TextOf(document, landed[0]));
        Assert.Equal(marked[4], TextOf(document, landed[1]));
    }

    [Fact]
    public void DuplicatedPagesAreFoundBesideTheirCopies()
    {
        var document = Open(4);
        var marked = Enumerable.Range(0, 4).Select(i => TextOf(document, i)).ToList();

        PageOperations.Duplicate(document, [1, 3]);

        Assert.Equal(6, document.Pages.Count);
        var found = PageEdits.Duplicated([3, 1]).ToList();
        Assert.Equal([1, 2, 4, 5], found);
        Assert.Equal(marked[1], TextOf(document, 1));
        Assert.Equal(marked[1], TextOf(document, 2));
        Assert.Equal(marked[3], TextOf(document, 5));
    }

    [Fact]
    public void ReplacingPagesPutsTheOthersInTheirPlace()
    {
        var target = Open(5);
        var source = PdfDocument.Open(Pdfs.Text(3, "From the other file."));
        var keep = TextOf(target, 4);

        PageEdits.Replace(target, [1, 2], source, [2, 0]);

        Assert.Equal(5, target.Pages.Count);
        Assert.Equal(TextOf(source, 2), TextOf(target, 1));
        Assert.Equal(TextOf(source, 0), TextOf(target, 2));
        Assert.Equal(keep, TextOf(target, 4));
    }

    [Fact]
    public void ADrawnBoxBecomesTheCropBoxOfEveryPageThroughItsOwnTurn()
    {
        var document = Open(2);
        PageOperations.Rotate(document, [1], 90);
        var upright = new PageGeometry(document.Pages[0]);
        var box = new DisplayRect(upright.Width / 8, upright.Height / 8, upright.Width / 4, upright.Height / 4);

        PageEdits.Crop(document, [0, 1], box);

        var first = new PageGeometry(document.Pages[0]);
        var second = new PageGeometry(document.Pages[1]);
        Assert.Equal(box.Width, first.Width, 1);
        Assert.Equal(box.Height, first.Height, 1);
        Assert.Equal(box.Width, second.Width, 1);
        Assert.Equal(box.Height, second.Height, 1);
        Assert.Equal(90, document.Pages[1].Rotate);
    }

    [Fact]
    public void LabelsCoverTheSelectionAndLeaveTheRestAsTheyWere()
    {
        var document = Open(8);
        PdfPageLabels.Write(document, [new PageLabelRange(0, PageLabelStyle.LowerRoman), new PageLabelRange(4, PageLabelStyle.Decimal)]);

        PageEdits.Relabel(document, 1, 2, PageLabelStyle.UpperLetters, "App-", 3);

        var labels = PdfPageLabels.Labels(document);
        Assert.Equal(["i", "App-C", "App-D", "iv", "1", "2", "3", "4"], labels);
    }

    [Fact]
    public void LabelsOnTheLastPagesNeedNoRestoringRange()
    {
        var document = Open(4);

        PageEdits.Relabel(document, 2, 3, PageLabelStyle.Decimal, "", 10);

        Assert.Equal(["1", "2", "10", "11"], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void ClearingLabelsRestoresPlainNumbers()
    {
        var document = Open(3);
        PageEdits.Relabel(document, 0, 2, PageLabelStyle.UpperRoman, "", 1);

        PageEdits.ClearLabels(document);

        Assert.Equal(["1", "2", "3"], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void ResizingKeepsEachPagesOrientation()
    {
        var document = Open(3);
        PageOperations.Rotate(document, [1], 90);

        PageEdits.ResizeTo(document, [0, 1, 2], 595.276, 841.89, ResizeMode.ChangeBox);

        var portrait = new PageGeometry(document.Pages[0]);
        var landscape = new PageGeometry(document.Pages[1]);
        Assert.Equal(595.276, portrait.Width, 1);
        Assert.Equal(841.89, portrait.Height, 1);
        Assert.Equal(841.89, landscape.Width, 1);
        Assert.Equal(595.276, landscape.Height, 1);
    }

    [Fact]
    public void ACopyForAnotherThreadHasTheCommittedPagesOnly()
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        PageOperations.Delete(tab.Document, [0]);
        tab.Commit("Delete pages");
        PageOperations.Rotate(tab.Document, [0], 90);

        var copy = PageEdits.Reopen(tab);

        Assert.Equal(2, copy.Pages.Count);
        Assert.Equal(0, copy.Pages[0].Rotate);
    }

    [Fact]
    public void ACopyOfAnEncryptedFileOpensWithTheTabsPassword()
    {
        var document = PdfDocument.Open(Pdfs.Text(2));
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        byte[] locked = document.SaveRewrite(new PdfSaveOptions(Security: security));
        using var tab = new DocumentTab(PdfEditSession.Open(locked, "open"), new FakeRenderer(), null, "locked.pdf", password: "open");

        var copy = PageEdits.Reopen(tab);

        Assert.Equal(2, copy.Pages.Count);
    }

    [Fact]
    public void ADeleteThatKeepsNoPageIsRefusedBeforeAnythingChanges()
    {
        var document = Open(2);

        Assert.ThrowsAny<ArgumentException>(() => PageOperations.Delete(document, [0, 1]));

        Assert.Equal(2, document.Pages.Count);
    }

    [Fact]
    public void NumberingTheFirstPagesOfAFileWithoutLabelsKeepsTheNumbersOfTheRest()
    {
        var document = Open(10);

        PageEdits.Relabel(document, 0, 2, PageLabelStyle.LowerRoman, "", 1);

        Assert.Equal(["i", "ii", "iii", "4", "5", "6", "7", "8", "9", "10"], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void NumberingPagesInsideAFileWithoutLabelsKeepsTheNumbersAroundThem()
    {
        var document = Open(6);

        PageEdits.Relabel(document, 2, 3, PageLabelStyle.UpperLetters, "", 1);

        Assert.Equal(["1", "2", "A", "B", "5", "6"], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void ABoxThatMissesALaterPageLeavesNoCropOnTheEarlierOnesOnceDiscarded()
    {
        var host = new RecordingHost();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), null, "a.pdf");
        PageOperations.SetBox(tab.Document, [1], PageBox.Crop, new PdfRect(0, 0, 100, 100));
        tab.Commit("Crop");
        var before = new PageGeometry(tab.Document.Pages[0]);
        var box = new DisplayRect(before.Width / 2, before.Height / 2, before.Width / 4, before.Height / 4);

        Assert.ThrowsAny<ArgumentException>(() => PageEdits.Crop(tab.Document, [0, 1], box));
        Assert.True(tab.Document.HasChanges);
        PageJobs.Refuse(host, tab);

        Assert.False(tab.Document.HasChanges);
        Assert.False(tab.Commit("Later"));
        Assert.Equal(before.Width, new PageGeometry(tab.Document.Pages[0]).Width, 1);
        Assert.Equal("Pages not changed", Assert.Single(host.Problems).Title);
    }

    [Fact]
    public void ThePaperListNamesGoThroughTheCatalog()
    {
        Assert.Contains(PaperSize.All, size => size.Name == Loc.T("Letter"));
        Assert.Contains(PaperSize.All, size => size.Name == Loc.T("Legal"));
    }

    [Fact]
    public void AFileOpenedWithoutTheOwnerRightsIsLockedOnlyWhenItRestrictsSomething()
    {
        var restricted = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print));
        var allowed = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.All));
        var owner = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");

        Assert.True(CopyRules.Locked(restricted));
        Assert.False(CopyRules.Locked(allowed));
        Assert.False(CopyRules.Locked(owner));
        Assert.False(CopyRules.Locked(Open()));
    }

    [Fact]
    public void ARefusedCopyIsReportedAndAFreeOneIsNot()
    {
        var host = new RecordingHost();

        Assert.True(CopyRules.Refused(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print)), host));
        Assert.False(CopyRules.Refused(Open(), host));

        Assert.Equal("File is protected", Assert.Single(host.Problems).Title);
    }

    [Fact]
    public void ANoticeIsGivenOnlyWhenTheSourceWasEncrypted()
    {
        var host = new RecordingHost();

        CopyRules.NoteUnprotected(Open(), host);
        CopyRules.NoteUnprotected(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.All)), host);

        Assert.Equal(["Copy is not protected"], host.Notices);
    }

    [Theory]
    [InlineData(10, 0, 0, 0, false)]
    [InlineData(10, 180, 20, 1, true)]
    [InlineData(10, 126, 20, 1, false)]
    [InlineData(10, 460, 20, 3, true)]
    [InlineData(10, 0, 170, 4, false)]
    [InlineData(10, 10, 340, 8, false)]
    public void APointInTheGridIsAssignedToTheCellItIsOver(int count, double x, double y, int index, bool after)
    {
        var (found, right) = TilePanel.Locate(new System.Windows.Point(x, y), 0, 116, 166, 4, count);

        Assert.Equal(index, found);
        Assert.Equal(after, right);
    }

    [Fact]
    public void AGapBetweenTilesDoesNotSendADroppedPageToTheEnd()
    {
        // Between the second and third column of the second row there is no tile; the drop still belongs to a neighbour.
        var (index, _) = TilePanel.Locate(new System.Windows.Point(116 * 2 - 1, 166 + 80), 0, 116, 166, 4, 100);

        Assert.Equal(5, index);
    }

    [Fact]
    public void ScrollingIsCountedInWhereAPointFalls()
    {
        var (index, _) = TilePanel.Locate(new System.Windows.Point(10, 10), 332, 116, 166, 4, 100);

        Assert.Equal(8, index);
    }

    [Fact]
    public void AnythingPastTheLastTileMeansTheEnd()
    {
        Assert.Equal((9, true), TilePanel.Locate(new System.Windows.Point(450, 600), 0, 116, 166, 4, 10));
        Assert.Equal((9, true), TilePanel.Locate(new System.Windows.Point(10, 700), 0, 116, 166, 4, 10));
    }

    private sealed class RecordingHost : IToolHost
    {
        public List<Problem> Problems { get; } = [];
        public List<string> Notices { get; } = [];

        public Task RunBusyAsync(string text, Func<CancellationToken, Task> work) => work(CancellationToken.None);

        public void ShowProblem(Problem problem) => Problems.Add(problem);

        public void ShowNotice(string title, string text, NoticeAction? action = null) => Notices.Add(title);

        public void SetStatus(string sentence) { }

        public Task OpenAsync(string path) => Task.CompletedTask;

        public Task OpenNewAsync(byte[] pdf, string title) => Task.CompletedTask;

        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }
}
