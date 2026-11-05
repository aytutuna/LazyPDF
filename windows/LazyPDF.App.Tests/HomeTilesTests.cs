using LazyPDF.App.Documents;
using Xunit;

namespace LazyPDF.App.Tests;

// The Home tab's tiles: the jobs people come for, each with its reason when it cannot start.
public sealed class HomeTilesTests
{
    private static readonly string[] Ids = ["open", "create", "combine", "compress", "protect", "sign", "form", "edit", "export", "batch"];

    [Fact]
    public void TheTilesAreTheTenJobsInOrder()
    {
        using var f = new ViewModelFixture();

        Assert.Equal(Ids, f.Vm.Tiles.Select(t => t.Id));
        Assert.Equal(["Open", "Create", "Combine", "Make smaller", "Protect", "Sign", "Fill a form", "Edit", "Export", "Batch"], f.Vm.Tiles.Select(t => t.Title));
    }

    [Fact]
    public void WithNoFileOnlyOpenIsAvailableAndTheOthersSayWhy()
    {
        using var f = new ViewModelFixture();

        foreach (var tile in f.Vm.Tiles.Where(t => t.Id is not ("open" or "create" or "batch")))
        {
            Assert.False(tile.Available);
            Assert.Equal("Open a file first", tile.Reason);
        }
        Assert.True(f.Vm.Tiles[0].Available);
        Assert.Null(f.Vm.Tiles[0].Reason);
    }

    [Fact]
    public void BatchNeedsNoFile()
    {
        using var f = new ViewModelFixture();
        var batch = f.Vm.Tiles.Single(t => t.Id == AppViewModel.BatchTile);

        Assert.True(batch.Available);
        Assert.Null(batch.Reason);
    }

    [Fact]
    public void ATileThatCannotStartTellsScreenReadersWhy()
    {
        using var f = new ViewModelFixture();

        Assert.Equal("Join files into a new one, or split this one. Not available: Open a file first", f.Vm.Tiles.Single(t => t.Id == "combine").HelpText);
        Assert.Equal("Open a PDF, a picture or a text file.", f.Vm.Tiles[0].HelpText);
    }

    [Fact]
    public void ScanIsOnlyThereWhenLazyScanIs()
    {
        using var f = new ViewModelFixture();
        Assert.DoesNotContain(f.Vm.Tiles, t => t.Id == "scan");

        f.Sisters.LazyScanInstalled = true;
        var tiles = f.Vm.Tiles.ToList();
        var scan = tiles.Single(t => t.Id == "scan");
        Assert.True(scan.Available);
        Assert.Null(scan.Reason);
        Assert.Equal("export", tiles[tiles.IndexOf(scan) + 1].Id);
    }

    [Fact]
    public async Task OnceAFileIsOpenTheToolTilesAreAvailable()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        f.Vm.ActiveTab = HomeTab.Instance;

        Assert.All(f.Vm.Tiles.Where(t => t.Id != "scan"), t =>
        {
            Assert.True(t.Available);
            Assert.Null(t.Reason);
        });
    }

    [Theory]
    [InlineData("combine", "combine")]
    [InlineData("compress", "optimize")]
    [InlineData("protect", "protect")]
    [InlineData("sign", "fillsign")]
    [InlineData("form", "forms")]
    [InlineData("edit", "editcontent")]
    [InlineData("export", "export")]
    public async Task ATileOpensItsToolOnTheDocumentLastInUse(string tile, string tool)
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf")]);
        f.Vm.ActiveTab = HomeTab.Instance;

        f.Vm.StartTile(tile);

        Assert.Equal(tool, f.Vm.ActiveToolId);
        Assert.Equal("b.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public void ATileThatCannotStartDoesNothing()
    {
        using var f = new ViewModelFixture();

        f.Vm.StartTile("combine");

        Assert.Null(f.Vm.ActiveToolId);
        Assert.True(f.Vm.IsHome);
    }

    [Fact]
    public void ScanStartsLazyScanOnlyWhenItIsThere()
    {
        using var f = new ViewModelFixture();

        f.Vm.StartTile("scan");
        Assert.Equal(0, f.Sisters.ScanOpened);

        f.Sisters.LazyScanInstalled = true;
        f.Vm.StartTile("scan");
        Assert.Equal(1, f.Sisters.ScanOpened);
    }

    [Fact]
    public void AToolTileWithoutAFileSaysToOpenOne()
    {
        using var f = new ViewModelFixture();

        f.Vm.StartTile("combine");

        Assert.Contains("Open a file first", f.Vm.StatusFull);
    }

    [Fact]
    public async Task AfterTheLastDocumentClosesTheTilesWaitForAFileAgain()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        f.Vm.Close(f.Vm.ActiveDocument!);

        Assert.False(f.Vm.Tiles.Single(t => t.Id == "combine").Available);
    }
}
