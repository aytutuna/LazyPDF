using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// The recovery folder: what each open document left after its last edit.
public sealed class RecoveryStoreTests
{
    private static RecoveryMeta Meta(string title, string? path = null) =>
        new() { Title = title, OriginalPath = path, Saved = DateTimeOffset.Now };

    [Fact]
    public void AWrittenDocumentIsListedWithItsBytesAndFacts()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        var id = Guid.NewGuid();

        store.Write(id, new byte[] { 1, 2, 3 }, Meta("a.pdf", @"C:\docs\a.pdf"));
        store.Flush();

        var entry = Assert.Single(store.List());
        Assert.Equal(id, entry.Id);
        Assert.Equal("a.pdf", entry.Meta.Title);
        Assert.Equal(@"C:\docs\a.pdf", entry.Meta.OriginalPath);
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(entry.PdfPath));
    }

    [Fact]
    public void ANewerWriteReplacesTheOlderOne()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        var id = Guid.NewGuid();

        store.Write(id, new byte[] { 1 }, Meta("a.pdf"));
        store.Write(id, new byte[] { 1, 2 }, Meta("a.pdf"));
        store.Flush();

        Assert.Equal(new byte[] { 1, 2 }, File.ReadAllBytes(Assert.Single(store.List()).PdfPath));
    }

    [Fact]
    public void DeleteTakesTheDocumentOut()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        var id = Guid.NewGuid();
        store.Write(id, new byte[] { 1 }, Meta("a.pdf"));

        store.Delete(id);

        Assert.Empty(store.List());
        Assert.False(Directory.Exists(dir.Path) && Directory.GetFiles(dir.Path).Length > 0);
    }

    [Fact]
    public void ADocumentDeletedBeforeItWasWrittenLeavesNothing()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        var id = Guid.NewGuid();

        for (int i = 0; i < 20; i++) store.Write(id, new byte[100_000], Meta("a.pdf"));
        store.Delete(id);

        Assert.Empty(store.List());
    }

    [Fact]
    public void TheNewestIsListedFirst()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        store.Write(Guid.NewGuid(), new byte[] { 1 }, new RecoveryMeta { Title = "old", Saved = DateTimeOffset.Now.AddHours(-2) });
        store.Write(Guid.NewGuid(), new byte[] { 1 }, new RecoveryMeta { Title = "new", Saved = DateTimeOffset.Now });
        store.Flush();

        Assert.Equal(["new", "old"], store.List().Select(e => e.Meta.Title));
    }

    [Fact]
    public void AFolderThatIsNotThereListsNothing()
    {
        using var dir = new TempDir();

        Assert.Empty(new RecoveryStore(dir.Sub("none")).List());
    }

    [Fact]
    public void ASweepOfAFolderThatIsNotThereDoesNothing()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Sub("none"));

        store.Sweep();

        Assert.Empty(store.List());
    }

    [Fact]
    public void AStrayFileIsNotADocument()
    {
        using var dir = new TempDir();
        dir.File("notes.json", [1]);
        dir.File(Guid.NewGuid().ToString("N") + ".json", [1]);

        Assert.Empty(new RecoveryStore(dir.Path).List());
    }
}
