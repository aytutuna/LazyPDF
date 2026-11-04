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

        f.Vm.CheckDisk();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task AChangedFileIsToldOnceWithAWayToOpenTheNewVersion()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        Touch(path, Pdfs.Text(pages: 3));

        f.Vm.CheckDisk();

        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.Contains("a.pdf", f.Vm.Message?.Text);
        Assert.NotNull(f.Vm.Message?.Action);
        f.Vm.DismissMessage();
        f.Vm.CheckDisk();
        Assert.Null(f.Vm.Message);
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

        f.Vm.CheckDisk();

        Assert.Contains("drops your unsaved changes", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task ADeletedFileSaysToSaveAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        File.Delete(path);

        f.Vm.CheckDisk();

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
        var tab = f.Vm.ActiveDocument!;
        Touch(path, Pdfs.Text(pages: 3));
        f.Vm.CheckDisk();
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

        f.Vm.CheckDisk();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public void OnTheHomeTabThereIsNothingToCheck()
    {
        using var f = new ViewModelFixture();

        f.Vm.CheckDisk();

        Assert.Null(f.Vm.Message);
    }
}
