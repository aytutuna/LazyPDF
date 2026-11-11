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
        f.Vm.SelectTool("stamps");
        Touch(path, 2, 10);
        await f.Vm.CheckDiskAsync();
        f.Vm.DismissMessage();

        Touch(path, 3, 20);
        await f.Vm.CheckDiskAsync();

        Assert.Equal("File changed", f.Vm.Message?.Title);
        Assert.NotNull(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task AFileDeletedAfterAChangeNoticeIsToldToo()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        await Task.Delay(100); // the check the open started must not meet the touch
        Touch(path, 2, 10);
        await f.Vm.CheckDiskAsync();
        f.Vm.DismissMessage();

        File.Delete(path);
        await f.Vm.CheckDiskAsync();

        Assert.Equal("File is gone", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task ComingToATabLooksAtItsFile()
    {
        using var f = new ViewModelFixture();
        string a = f.Pdf("a.pdf");
        await f.Vm.OpenFilesAsync([a, f.Pdf("b.pdf")]);
        f.Vm.SelectTool("stamps");
        Touch(a, 2, 10);
        f.Vm.DismissMessage();

        f.Vm.ActiveTab = f.Vm.Documents.First();
        for (int i = 0; i < 100 && f.Vm.Message is null; i++) await Task.Delay(50);

        Assert.Equal("File changed", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task OpeningTheNewVersionClearsWhatWasToldAboutTheOldOne()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.SelectTool("stamps");
        Touch(path, 2, 10);
        await f.Vm.CheckDiskAsync();
        await f.Vm.ReloadAsync(f.Vm.ActiveDocument!);
        f.Vm.DismissMessage();

        await f.Vm.CheckDiskAsync();
        Assert.Null(f.Vm.Message);

        Touch(path, 3, 20);
        await f.Vm.CheckDiskAsync();
        Assert.Equal("File changed", f.Vm.Message?.Title);
    }
}
