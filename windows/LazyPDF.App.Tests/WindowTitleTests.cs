using Xunit;

namespace LazyPDF.App.Tests;

public sealed class WindowTitleTests
{
    [Fact]
    public async Task TheTitleNamesTheDocumentInView()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("report.pdf"));

        Assert.Equal("report.pdf - Lazy PDF", MainWindow.TitleOf(f.Vm.ActiveDocument));
    }

    [Fact]
    public void HomeKeepsTheNameOfTheApp()
    {
        Assert.Equal("Lazy PDF", MainWindow.TitleOf(null));
    }
}
