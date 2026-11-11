using Xunit;

namespace LazyPDF.App.Tests;

// A copy goes to another file and leaves the tab as it was.
public sealed class SaveCopyTests
{
    [Fact]
    public async Task ACopyHoldsTheCurrentContentAndChangesNothingInTheTab()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Edited");
        tab.Commit("Properties");
        string copy = f.Dir.Sub("copy.pdf");

        Assert.True(f.Vm.SaveCopy(tab, copy));

        Assert.Equal(tab.Session.Current.ToArray(), File.ReadAllBytes(copy));
        Assert.Equal(path, tab.Path);
        Assert.Equal("report.pdf", tab.Title);
        Assert.True(tab.IsDirty);
        Assert.Equal("Saved a copy of report.pdf.", f.Vm.StatusFull);
    }

    [Fact]
    public async Task ThePathOfTheTabItselfIsRefused()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        byte[] before = File.ReadAllBytes(path);

        Assert.False(f.Vm.SaveCopy(tab, path.ToUpperInvariant()));

        Assert.Equal("File is open", f.Vm.Message?.Title);
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task APathOpenInAnotherTabIsRefused()
    {
        using var f = new ViewModelFixture();
        string other = f.Pdf("other.pdf");
        await f.Vm.OpenAsync(other);
        await f.Vm.OpenAsync(f.Pdf("report.pdf"));
        byte[] before = File.ReadAllBytes(other);

        Assert.False(f.Vm.SaveCopy(f.Vm.ActiveDocument!, other));

        Assert.Equal("File is open", f.Vm.Message?.Title);
        Assert.Equal(before, File.ReadAllBytes(other));
    }
}
