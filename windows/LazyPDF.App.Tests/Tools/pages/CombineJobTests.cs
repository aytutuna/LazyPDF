using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Combine;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Combine and split against the real engine: the parts a file is cut into, their names, and the files that are read in.
[Collection("Application")]
public sealed class CombineJobTests
{
    private sealed class RecordingHost : IToolHost
    {
        public List<Problem> Problems { get; } = [];

        public Task RunBusyAsync(string text, Func<CancellationToken, Task> work) => work(CancellationToken.None);

        public void ShowProblem(Problem problem) => Problems.Add(problem);

        public List<(string Title, string Text)> Notices { get; } = [];

        public void ShowNotice(string title, string text, NoticeAction? action = null) => Notices.Add((title, text));

        public void SetStatus(string sentence) { }

        public Task OpenAsync(string path) => Task.CompletedTask;

        public Task<bool> OpenNewAsync(byte[] pdf, string title) => Task.FromResult(true);

        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }

    private static PdfDocument WithBookmarks(int pages, params int[] starts)
    {
        var session = PdfEditSession.Open(Pdfs.Text(pages));
        var outline = Outline.Read(session.Document);
        foreach (int start in starts) outline.Add(new OutlineItem { Title = $"Part {start}", Destination = new PdfDestination(start) });
        outline.Write(session.Document);
        session.Commit("Bookmarks");
        return PdfDocument.Open(session.Current.ToArray());
    }

    [Theory]
    [InlineData(SplitBy.Count, "10", true, 10)]
    [InlineData(SplitBy.Count, "0", false, 0)]
    [InlineData(SplitBy.Count, "2.5", false, 0)]
    [InlineData(SplitBy.Count, "many", false, 0)]
    [InlineData(SplitBy.Size, "0.5", true, 0.5)]
    [InlineData(SplitBy.Size, "0", false, 0)]
    [InlineData(SplitBy.Bookmarks, "", true, 0)]
    public void AnAmountIsAcceptedOnlyWhenItMakesSenseForTheKindOfSplit(SplitBy by, string text, bool valid, double expected)
    {
        using var culture = new CultureScope("en-US");

        Assert.Equal(valid, CombineJob.TryAmount(by, text, out double amount));
        if (valid) Assert.Equal(expected, amount);
    }

    [Fact]
    public void TheEntryThatCannotBeMergedIsNamed()
    {
        var good = PdfDocument.Open(Pdfs.Text(3));
        var bad = PdfDocument.Open(Pdfs.Text(2));
        var open = PdfDocument.Open(Pdfs.Text(1));

        var fine = new[] { (new CombineEntry("a.pdf", 3, good), (List<int>?)null) };
        var broken = new[] { (new CombineEntry("a.pdf", 3, good), (List<int>?)null), (new CombineEntry("b.pdf", 2, bad), (List<int>?)[99]) };

        Assert.Null(CombinePanel.FirstUnmergeable(open, fine));
        Assert.Equal("b.pdf", CombinePanel.FirstUnmergeable(open, broken));
    }

    [Fact]
    public void SplittingByCountMakesPartsOfThatManyPages()
    {
        var source = PdfDocument.Open(Pdfs.Text(7));

        var parts = CombineJob.Split(source, SplitBy.Count, 3);

        Assert.Equal([3, 3, 1], parts.Select(p => p.Pages.Count));
    }

    [Fact]
    public void ACancelledSplitStopsInsteadOfMakingParts()
    {
        var source = PdfDocument.Open(Pdfs.Text(7));
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();

        Assert.Throws<OperationCanceledException>(() => CombineJob.Split(source, SplitBy.Size, 0.01, cancel.Token));
        Assert.Throws<OperationCanceledException>(() => CombineJob.Split(source, SplitBy.Count, 2, cancel.Token));
    }

    [Fact]
    public void SplittingByBookmarksCutsAtTheTopLevelOnes()
    {
        var source = WithBookmarks(6, 0, 2, 5);

        var parts = CombineJob.Split(source, SplitBy.Bookmarks, 0);

        Assert.Equal([2, 3, 1], parts.Select(p => p.Pages.Count));
    }

    [Fact]
    public void SplittingByEachPageMakesOnePagePerPart()
    {
        var parts = CombineJob.Split(PdfDocument.Open(Pdfs.Text(4)), SplitBy.EachPage, 0);

        Assert.Equal([1, 1, 1, 1], parts.Select(p => p.Pages.Count));
    }

    [Fact]
    public void TypedRangesAreSplitAtSemicolons()
    {
        var (ranges, error) = CombineJob.ParseRanges("1-3; 4-6, 9", 10);

        Assert.Null(error);
        Assert.Equal([[0, 1, 2], [3, 4, 5, 8]], ranges.Select(r => r.ToArray()));
    }

    [Fact]
    public void ARangeThatCannotBeReadNamesItself()
    {
        using var culture = new CultureScope("en-US");

        var (_, error) = CombineJob.ParseRanges("1-3; x", 10);

        Assert.StartsWith("x: ", error);
        Assert.Equal("Type at least one range.", CombineJob.ParseRanges(" ; ", 10).Error);
        Assert.False(CombineJob.TryAmount(SplitBy.Ranges, "", out _, 10));
        Assert.True(CombineJob.TryAmount(SplitBy.Ranges, "2", out _, 10));
    }

    [Fact]
    public void OverlappingRangesShareAPage()
    {
        var source = PdfDocument.Open(Pdfs.Text(6));
        var (ranges, _) = CombineJob.ParseRanges("1-3; 3-5", 6);

        var parts = CombineJob.Split(source, SplitBy.Ranges, 0, ranges: ranges);

        Assert.Equal([3, 3], parts.Select(p => p.Pages.Count));
    }

    [Fact]
    public void BookmarksThatPointNowhereAreIgnored()
    {
        var source = WithBookmarks(3, 1);
        var outline = Outline.Read(source);
        outline.Add(new OutlineItem { Title = "Nowhere", Destination = new PdfDestination(-1) });

        Assert.Equal([1], CombineJob.BookmarkStarts(source));
    }

    [Fact]
    public void ASizeLimitGivesPartsThatFitIt()
    {
        var source = PdfDocument.Open(Pdfs.Text(12));
        long whole = source.SaveRewrite().Length;
        double megabytes = whole / 2.0 / CombineJob.MegabyteBytes;

        var parts = CombineJob.Split(source, SplitBy.Size, megabytes);

        Assert.True(parts.Count >= 2);
        Assert.Equal(12, parts.Sum(p => p.Pages.Count));
        Assert.All(parts, part => Assert.True(part.SaveRewrite().Length <= megabytes * CombineJob.MegabyteBytes || part.Pages.Count == 1));
    }

    [Fact]
    public void PartsAreNumberedToTheWidthOfTheCount()
    {
        Assert.Equal("Report 2.pdf", CombineJob.PartName("Report", 1, 5));
        Assert.Equal("Report 02.pdf", CombineJob.PartName("Report", 1, 12));
        Assert.Equal("Report 012.pdf", CombineJob.PartName("Report", 11, 120));
    }

    [Fact]
    public void PartsAreNamedAfterTheirBookmarks()
    {
        var source = WithBookmarks(8, 0, 3, 6);

        var titles = CombineJob.BookmarkTitles(source);

        Assert.Equal(["Part 0", "Part 3", "Part 6"], titles);
        Assert.Equal("doc - Part 3.pdf", CombineJob.PartName("doc", 1, 3, titles[1]));
    }

    [Fact]
    public void AFirstPartWithoutABookmarkKeepsItsNumber()
    {
        var titles = CombineJob.BookmarkTitles(WithBookmarks(8, 3, 6));

        Assert.Equal([null, "Part 3", "Part 6"], titles);
        Assert.Equal("doc 1.pdf", CombineJob.PartName("doc", 0, 3, titles[0]));
    }

    [Fact]
    public void TwoBookmarksOnOnePageUseTheFirst()
    {
        var source = WithBookmarks(5, 2);
        var outline = Outline.Read(source);
        outline.Add(new OutlineItem { Title = "Second", Destination = new PdfDestination(2) });
        outline.Write(source);

        Assert.Equal([null, "Part 2"], CombineJob.BookmarkTitles(source));
    }

    [Theory]
    [InlineData("A/B: C", "doc - A_B_ C.pdf")]
    [InlineData("a   b", "doc - a b.pdf")]
    [InlineData(" .Intro. ", "doc - Intro.pdf")]
    [InlineData("con", "doc 2.pdf")]
    [InlineData("LPT3", "doc 2.pdf")]
    [InlineData("...", "doc 2.pdf")]
    public void ATitleIsMadeIntoAFileName(string title, string expected)
    {
        Assert.Equal(expected, CombineJob.PartName("doc", 1, 3, title));
    }

    [Fact]
    public void ALongTitleIsCut()
    {
        Assert.Equal($"doc - {new string('x', 80)}.pdf", CombineJob.PartName("doc", 1, 3, new string('x', 200)));
    }

    [Fact]
    public void ANameTakenInTheFolderGetsANumber()
    {
        using var dir = new TempDir();
        dir.File("Report 1.pdf", [1]);
        dir.File("Report 1 (2).pdf", [1]);

        Assert.Equal(dir.Sub("Report 1 (3).pdf"), CombineJob.UniquePath(dir.Path, "Report 1.pdf"));
        Assert.Equal(dir.Sub("Other.pdf"), CombineJob.UniquePath(dir.Path, "Other.pdf"));
    }

    [Fact]
    public void FilesMergeWithTheirRangesInTheOrderOfTheList()
    {
        var first = PdfDocument.Open(Pdfs.Text(4));
        var second = PdfDocument.Open(Pdfs.Text(3));

        var merged = PageAssembly.Merge([new MergeSource(second, PageRange.Parse("2-3", 3).Pages), new MergeSource(first, null), new MergeSource(second, PageRange.Parse("1", 3).Pages)]);

        Assert.Equal(7, merged.Pages.Count);
    }

    [Fact]
    public void EachFileGetsABookmarkAtItsFirstPage()
    {
        var a = PdfDocument.Open(Pdfs.Text(3));
        var b = PdfDocument.Open(Pdfs.Text(4));
        var merged = PageAssembly.Merge([new MergeSource(a, [0, 1]), new MergeSource(a, null), new MergeSource(b, PageRange.Parse("2-3", 4).Pages)]);

        CombineJob.AddFileBookmarks(merged, [("One.pdf", 2), (" Two.PDF ", 3), ("Three", 2)]);

        var items = Outline.Read(PdfDocument.Open(merged.SaveRewrite())).Items;
        Assert.Equal(["One", "Two", "Three"], items.Select(item => item.Title));
        Assert.Equal([0, 2, 5], items.Select(item => item.Destination!.PageIndex));
    }

    [Theory]
    [InlineData("Report.pdf", "Report")]
    [InlineData("  Notes.PDF", "Notes")]
    [InlineData("scan.v2", "scan.v2")]
    [InlineData(".pdf", "File 3")]
    public void BookmarkTitleDropsThePdfExtension(string name, string expected)
    {
        using var culture = new CultureScope("en-US");

        Assert.Equal(expected, CombineJob.BookmarkTitle(name, 3));
    }

    [Fact]
    public async Task AFileThatCannotBeReadIsReportedAndLeftOut()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        string bad = dir.File("bad.pdf", [1, 2, 3, 4]);
        string good = dir.File("good.pdf", Pdfs.Text(2));
        string missing = dir.Sub("gone.pdf");

        Assert.Null(await SourceFile.OpenAsync(host, bad));
        Assert.Null(await SourceFile.OpenAsync(host, missing));
        var opened = await SourceFile.OpenAsync(host, good);

        Assert.Equal(2, opened!.Pages.Count);
        Assert.Equal(["Not a PDF", "File not found"], host.Problems.Select(p => p.Title));
    }

    private static string LockedFile(TempDir dir)
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        var security = PdfSecurity.Create("secret", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return dir.File("locked.pdf", document.SaveRewrite(new PdfSaveOptions(Security: security)));
    }

    [Fact]
    public async Task ALockedFileIsOpenedWithThePasswordTheAskerGives()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        var asked = new List<bool>();

        var opened = await SourceFile.OpenAsync(host, LockedFile(dir), (name, wrong) =>
        {
            asked.Add(wrong);
            return wrong ? "secret" : "guess";
        });

        Assert.Equal(3, opened!.Pages.Count);
        Assert.Equal([false, true], asked);
        Assert.Empty(host.Problems);
    }

    [Fact]
    public async Task GivingUpOnThePasswordLeavesTheFileOutWithoutAProblem()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();

        Assert.Null(await SourceFile.OpenAsync(host, LockedFile(dir), (_, _) => null));

        Assert.Empty(host.Problems);
    }

    [Fact]
    public void BookmarksOnTheSamePageOrTheFirstMakeNoExtraPart()
    {
        Assert.Equal(1, CombineJob.BookmarkParts(WithBookmarks(5, 0, 0)));
        Assert.Equal(2, CombineJob.BookmarkParts(WithBookmarks(5, 0, 3, 3)));
        Assert.Equal(3, CombineJob.BookmarkParts(WithBookmarks(5, 1, 3)));
    }

    [Fact]
    public void ARangeTypedInAnEntryIsAnnounced()
    {
        var entry = new CombineEntry("a.pdf", 3, null);
        var changed = new List<string?>();
        entry.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        entry.Range = "1-3";

        Assert.Equal("1-3", entry.Range);
        Assert.Contains("Range", changed);
    }

    [Fact]
    public void TheEntryOfTheOpenFileFollowsItsPageCount()
    {
        var entry = new CombineEntry("a.pdf", 3, null);
        var changed = new List<string?>();
        entry.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        entry.Pages = 5;

        Assert.Equal("5 pages", entry.Detail);
        Assert.Contains("Detail", changed);
    }

    private sealed class CultureScope : IDisposable
    {
        private readonly System.Globalization.CultureInfo _before = System.Globalization.CultureInfo.CurrentCulture;

        public CultureScope(string name) => System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo(name);

        public void Dispose() => System.Globalization.CultureInfo.CurrentCulture = _before;
    }

    [Fact]
    public void PartsOverCountsOnlyThoseBiggerThanTheLimit()
    {
        var parts = new List<byte[]> { new byte[99], new byte[100], new byte[101], new byte[500] };
        Assert.Equal(2, CombineJob.PartsOver(parts, 100));
    }

    [Fact]
    public async Task APictureBecomesAnEntryOfOnePage()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        string png = dir.File("photo.png", PngWriter.Encode(new PdfRgbaImage(8, 8, Enumerable.Repeat((byte)200, 8 * 8 * 4).ToArray())));
        var list = new List<CombineEntry>();

        Assert.True(await CombinePanel.AddAsync(host, list, [png]));

        var entry = Assert.Single(list);
        Assert.Equal("photo.png", entry.Name);
        Assert.Equal(1, entry.Pages);
    }

    [Fact]
    public async Task APictureThatCannotBeReadIsReportedAndNotListed()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        string bad = dir.File("broken.png", [1, 2, 3]);
        var list = new List<CombineEntry>();

        Assert.False(await CombinePanel.AddAsync(host, list, [bad]));

        Assert.Empty(list);
        Assert.Equal([("Picture not read", "broken.png could not be read as a picture.")], host.Notices);
    }

    [Fact]
    public void ADroppedFolderGivesItsPdfsInNameOrder()
    {
        using var dir = new TempDir();
        string folder = System.IO.Path.Combine(dir.Path, "set");
        Directory.CreateDirectory(folder);
        string b = System.IO.Path.Combine(folder, "b.pdf"), a = System.IO.Path.Combine(folder, "a.pdf");
        File.WriteAllBytes(b, Pdfs.Text(1));
        File.WriteAllBytes(a, Pdfs.Text(1));
        File.WriteAllText(System.IO.Path.Combine(folder, "notes.txt"), "x");
        string loose = dir.File("loose.docx", [1]);

        var files = CombinePanel.Gather(new RecordingHost(), [folder, loose], out int skipped);

        Assert.Equal([a, b], files);
        Assert.Equal(1, skipped);
    }

    [Fact]
    public async Task AFileWithNoPagesIsRefusedAndNotListed()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        string noPages = dir.File("empty.pdf", ExportPdf.NewDocument().SaveRewrite());
        string good = dir.File("good.pdf", Pdfs.Text(2));
        var list = new List<CombineEntry>();

        bool all = await CombinePanel.AddAsync(host, list, [noPages, good]);

        Assert.False(all);
        Assert.Equal(["good.pdf"], list.Select(e => e.Name));
        Assert.Equal([("Nothing to add", "empty.pdf has no pages, so it was left out.")], host.Notices);
    }

    [Fact]
    public void TheFolderNoticeJoinsItsSentencesWithFullStops()
    {
        Assert.Equal("out", CombineJob.FolderNote("out", false, ""));
        Assert.Equal("out. Big.", CombineJob.FolderNote("out", false, "Big."));
        Assert.Equal("out. " + CopyRules.Unprotected + " Big.", CombineJob.FolderNote("out", true, "Big."));
    }

    [Theory]
    [InlineData(0, 2, true, 2)]
    [InlineData(0, 2, false, 1)]
    [InlineData(2, 0, false, 0)]
    [InlineData(2, 0, true, 1)]
    [InlineData(1, 1, false, 1)]
    [InlineData(1, 1, true, 1)]
    public void ADroppedCardLandsOnTheSideOfTheCardUnderIt(int from, int over, bool lowerHalf, int expected)
    {
        Assert.Equal(expected, CombinePanel.TargetIndex(from, over, lowerHalf));
    }

    [Fact]
    public void ASizeSplitWithAnOversizePageSaysSoInTheFolderNotice()
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        var parts = new List<byte[]> { new byte[10], new byte[2_000_000], new byte[3_000_000] };

        Directory.CreateDirectory(dir.Path);
        CombinePanel.Saved(host, dir.Path, [("a.pdf", parts[0])], false, CombineJob.Oversize(parts, 1));

        Assert.Equal(dir.Path + ". 2 parts are bigger than 1 MB. A single page is too large to fit.", host.Notices.Single().Text);
    }

    [Theory]
    [InlineData(SplitBy.Count, 100, 10, 10)]
    [InlineData(SplitBy.Count, 7, 10, 1)]
    [InlineData(SplitBy.EachPage, 40, 0, 40)]
    [InlineData(SplitBy.Size, 40, 5, null)]
    public void TheNumberOfPartsIsKnownBeforeTheSplitRunsOnlyForPagesAndEachPage(SplitBy by, int pages, double amount, int? expected)
    {
        Assert.Equal(expected, CombineJob.EstimatedParts(by, pages, amount));
    }

    [Fact]
    public Task ManyPartsSwitchTheResultToAFolderUntilThePersonPicks() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(50)), new FakeRenderer(), null, "a.pdf", null);
        var panel = new CombinePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        var output = (System.Windows.Controls.ComboBox)panel.FindName("Output");
        ((System.Windows.Controls.RadioButton)panel.FindName("ModeSplit")).IsChecked = true;

        Assert.Equal(1, output.SelectedIndex);

        output.SelectedIndex = 0;
        ((System.Windows.Controls.TextBox)panel.FindName("Amount")).Text = "5";

        Assert.Equal(0, output.SelectedIndex);
        return Task.CompletedTask;
    });
}
