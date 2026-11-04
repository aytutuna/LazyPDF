using Xunit;

namespace LazyPDF.App.Tests;

// The file under an open tab is looked at when its tab comes forward, and each new state of it is told once.
public sealed class DiskNoticeTests
{
    private static void Touch(string path, int pages, int minutes)
    {
        File.WriteAllBytes(path, Pdfs.Text(pages));
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(minutes));
    }

    [Fact]
    public async Task AChangeAfterADismissedNoticeIsToldAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        Touch(path, 2, 10);
        f.Vm.CheckDisk();
        f.Vm.DismissMessage();

        Touch(path, 3, 20);
        f.Vm.CheckDisk();

        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.NotNull(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task AFileDeletedAfterAChangeNoticeIsToldToo()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        Touch(path, 2, 10);
        f.Vm.CheckDisk();
        f.Vm.DismissMessage();

        File.Delete(path);
        f.Vm.CheckDisk();

        Assert.Equal("File is gone", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task ComingToATabLooksAtItsFile()
    {
        using var f = new ViewModelFixture();
        string a = f.Pdf("a.pdf");
        await f.Vm.OpenFilesAsync([a, f.Pdf("b.pdf")]);
        Touch(a, 2, 10);
        f.Vm.DismissMessage();

        f.Vm.ActiveTab = f.Vm.Documents.First();

        Assert.Equal("File changed", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task OpeningTheNewVersionClearsWhatWasToldAboutTheOldOne()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        Touch(path, 2, 10);
        f.Vm.CheckDisk();
        await f.Vm.ReloadAsync(f.Vm.ActiveDocument!);
        f.Vm.DismissMessage();

        f.Vm.CheckDisk();
        Assert.Null(f.Vm.Message);

        Touch(path, 3, 20);
        f.Vm.CheckDisk();
        Assert.Equal("File changed", f.Vm.Message?.Title);
    }
}
