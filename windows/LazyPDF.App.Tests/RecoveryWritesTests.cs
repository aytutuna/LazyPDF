using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The recovery copy follows the document: written for every edit, gone when the document is clean, and not mistaken for a live one.
public sealed class RecoveryWritesTests
{
    [Fact]
    public void AWriteJustAfterTheWorkerFinishedIsStillWritten()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        var id = Guid.NewGuid();

        for (int i = 1; i <= 300; i++)
        {
            store.Write(id, new byte[] { (byte)(i % 250), (byte)i }, new RecoveryMeta { Title = i.ToString() });
            if (i % 7 == 0) Thread.Yield();
            store.Flush();
            var entry = Assert.Single(store.List());
            Assert.Equal(i.ToString(), entry.Meta.Title);
        }
    }

    [Fact]
    public void UndoingBackToTheSavedStateRemovesTheCopy()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Sub("recovery"));
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text()), new FakeRenderer(), null, "a.pdf", recovery: store);
        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");
        store.Flush();
        Assert.Single(store.List());

        tab.Undo();
        store.Flush();

        Assert.False(tab.IsDirty);
        Assert.Empty(store.List());
    }

    [Fact]
    public void EntriesOfAProcessThatIsStillRunningAreNotCrashLeftovers()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        store.Write(Guid.NewGuid(), new byte[] { 1 }, new RecoveryMeta { Title = "live", ProcessId = Environment.ProcessId });
        store.Write(Guid.NewGuid(), new byte[] { 1 }, new RecoveryMeta { Title = "gone", ProcessId = int.MaxValue });
        store.Write(Guid.NewGuid(), new byte[] { 1 }, new RecoveryMeta { Title = "old" });
        store.Flush();

        Assert.Equal(3, store.List().Count);
        Assert.Equal(["gone", "old"], store.Abandoned().Select(e => e.Meta.Title).Order());
    }

    [Fact]
    public async Task AWindowBesideALiveOneDoesNotOfferItsDocuments()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        Pdfs.Retitle(f.Vm.ActiveDocument!.Session, "Unsaved");
        f.Vm.ActiveDocument.Commit("Properties");
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        for (int i = 0; i < 100 && store.List().Count == 0; i++) Thread.Sleep(20);
        Assert.Single(store.List());
        var beside = new AppViewModel(() => new FakeRenderer(), new FakeCodec(), new FakeFonts(), f.Sisters, f.Dir.Sub("settings2"), f.Dir.Sub("recovery"), f.Dir.Sub("print"));

        beside.CheckRecovery();

        Assert.Null(beside.RecoveryOffer);
    }
}
