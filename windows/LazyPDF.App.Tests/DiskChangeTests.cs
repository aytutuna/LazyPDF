using LazyPDF.App.Documents;
using Xunit;

namespace LazyPDF.App.Tests;

// A file changed under the app's hands is noticed once, and the new version can be opened in its place.
public sealed class DiskChangeTests
{
    private static void Touch(string path, byte[] bytes)
    {
        File.WriteAllBytes(path, bytes);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(10));
    }

    [Fact]
    public async Task AnUnchangedFileSaysNothing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        await f.Vm.CheckDiskAsync();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task AChangedFileIsToldOnceWithAWayToOpenTheNewVersion()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.Contains("a.pdf", f.Vm.Message?.Text);
        Assert.NotNull(f.Vm.Message?.Action);
        f.Vm.DismissMessage();
        await f.Vm.CheckDiskAsync();
        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task ACleanTabWithAChangedFileIsReloadedQuietly()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("a.pdf");
        await f.Vm.OpenFilesAsync([path, f.Pdf("b.pdf")]);
        f.Vm.ActiveTab = f.Vm.Documents.First();
        var old = f.Vm.ActiveDocument!;
        await f.Vm.DiskCheck;
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.NotSame(old, f.Vm.Documents.First());
        Assert.Equal(3, f.Vm.Documents.First().PageCount);
        Assert.Equal(["a.pdf", "b.pdf"], f.Vm.Documents.Select(d => d.Title));
        Assert.Equal("Reloaded a.pdf", f.Vm.StatusShort);
        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task AGarbageFileFallsBackToTheNotice()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var old = f.Vm.ActiveDocument!;
        await f.Vm.DiskCheck;
        Touch(path, "%PDF-1.7 half"u8.ToArray());

        await f.Vm.CheckDiskAsync();

        Assert.Same(old, f.Vm.ActiveDocument);
        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.NotNull(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task ADirtyTabIsNotReloaded()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.Same(tab, f.Vm.ActiveDocument);
        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.NotNull(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task WithAToolOpenTheTabIsNotReloaded()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        f.Vm.SelectTool("stamps");
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.Same(tab, f.Vm.ActiveDocument);
        Assert.Equal("File changed", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task ATabWithMeasurementsNotAddedIsNotReloadedQuietly()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMeasurements = 2;
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.Same(tab, f.Vm.ActiveDocument);
        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.Contains("not applied yet", f.Vm.Message?.Text);
    }

    [Fact]
    public void TwoChecksAtOnceReloadTheTabOnce()
    {
        // The window's thread runs both checks one after the other, as OneThread does.
        OneTabPerFileTests.OneThread.Run(async () =>
        {
            using var f = new ViewModelFixture();
            string path = f.Pdf();
            await f.Vm.OpenAsync(path);
            await f.Vm.DiskCheck;
            Touch(path, Pdfs.Text(pages: 3));

            await Task.WhenAll(f.Vm.CheckDiskAsync(), f.Vm.CheckDiskAsync());

            Assert.Single(f.Vm.Documents);
            Assert.Equal(3, f.Vm.ActiveDocument!.PageCount);
        });
    }

    [Fact]
    public async Task AFileOnlyTouchedIsNotAChange()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        Touch(path, File.ReadAllBytes(path));

        await f.Vm.CheckDiskAsync();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task DifferentBytesOfTheSameLengthAreAChange()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        var bytes = File.ReadAllBytes(path);
        bytes[^1] ^= 1;
        Touch(path, bytes);

        await f.Vm.CheckDiskAsync();

        Assert.Equal("File changed", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task ASameLengthChangeAlreadyToldIsNotCheckedAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        var bytes = File.ReadAllBytes(path);
        bytes[^1] ^= 1;
        Touch(path, bytes);
        await f.Vm.CheckDiskAsync();
        f.Vm.DismissMessage();

        await f.Vm.CheckDiskAsync();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task ASavedTabWithATouchedFileIsStillNoticed()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        f.Vm.Save(tab);
        f.Vm.DismissMessage();
        Touch(path, File.ReadAllBytes(path));

        await f.Vm.CheckDiskAsync();

        Assert.Equal("File changed", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task WithUnsavedChangesTheNoticeSaysTheyWouldBeLost()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.CheckDiskAsync();

        Assert.Contains("drops your unsaved changes", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task ADeletedFileSaysToSaveAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        File.Delete(path);

        await f.Vm.CheckDiskAsync();

        Assert.Equal("File is gone", f.Vm.Message?.Title);
        Assert.Null(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task OpeningTheNewVersionReplacesTheTabInTheSamePlace()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("a.pdf");
        await f.Vm.OpenFilesAsync([path, f.Pdf("b.pdf")]);
        var old = f.Vm.Documents.First();
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.ReloadAsync(old);

        Assert.Equal(["a.pdf", "b.pdf"], f.Vm.Documents.Select(d => d.Title));
        Assert.Equal(3, f.Vm.Documents.First().PageCount);
        Assert.NotSame(old, f.Vm.Documents.First());
    }

    [Fact]
    public async Task TheNewVersionKeepsThePageAndRotationOfTheOldOne()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var old = f.Vm.ActiveDocument!;
        old.PageIndex = 1;
        old.Rotation = 90;
        Touch(path, Pdfs.Text(pages: 3));

        await f.Vm.ReloadAsync(old);

        Assert.Equal(1, f.Vm.ActiveDocument!.PageIndex);
        Assert.Equal(90, f.Vm.ActiveDocument.Rotation);
    }

    [Fact]
    public async Task ReloadingTheActiveTabTellsTheWindowAboutTheNewOne()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var old = f.Vm.ActiveDocument!;
        Touch(path, Pdfs.Text(pages: 3));
        var seen = new List<DocumentTab?>();
        f.Vm.PropertyChanged += (_, _) => seen.Add(f.Vm.ActiveDocument);

        await f.Vm.ReloadAsync(old);

        Assert.NotSame(old, f.Vm.ActiveDocument);
        Assert.Same(f.Vm.ActiveDocument, seen[^1]);
    }

    [Fact]
    public async Task TheButtonOfANoticeGoesWhenTheTabIsClosed()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        var tab = f.Vm.ActiveDocument!;
        Touch(path, Pdfs.Text(pages: 3));
        await f.Vm.CheckDiskAsync();
        Assert.NotNull(f.Vm.Message?.Action);

        f.Vm.Close(tab);

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task OurOwnSaveIsNotReportedAsAChange()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        f.Vm.Save(tab);
        f.Vm.DismissMessage();

        await f.Vm.CheckDiskAsync();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task OnTheHomeTabThereIsNothingToCheck()
    {
        using var f = new ViewModelFixture();

        await f.Vm.CheckDiskAsync();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public void ALeftTabIsNotToldAboutAfterTheCheckFinishes()
    {
        // In the app the check comes back on the window's thread, after the tab is left, never before.
        OneTabPerFileTests.OneThread.Run(async () =>
        {
            using var f = new ViewModelFixture();
            string a = f.Pdf("a.pdf");
            await f.Vm.OpenFilesAsync([f.Pdf("b.pdf"), a]);
            Assert.Equal(a, f.Vm.ActiveDocument!.Path);
            Touch(a, Pdfs.Text(pages: 3));

            var check = f.Vm.CheckDiskAsync();
            f.Vm.ActiveTab = f.Vm.Documents.First();
            await check;

            Assert.Null(f.Vm.Message);
        });
    }
}
