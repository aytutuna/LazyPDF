using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Combine;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Combine and split against the real engine: the parts a file is cut into, their names, and the files that are read in.
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
}
