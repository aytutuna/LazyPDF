using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Unsaved work is never given up before something else holds it: a restore, a reload and a save over a changed file.
public sealed class DocumentLossTests
{
    private static void Touch(string path, byte[] bytes)
    {
        File.WriteAllBytes(path, bytes);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(10));
    }

    private static string Locked(ViewModelFixture f) => f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));

    // A crash left the locked file behind with the password still needed to read it.
    private static RecoveryStore CrashedLocked(ViewModelFixture f)
    {
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        store.Write(Guid.NewGuid(), File.ReadAllBytes(Pdfs.Fixture("locked.pdf")), new RecoveryMeta { Title = "locked.pdf", Saved = DateTimeOffset.Now });
        store.Flush();
        return store;
    }

    [Fact]
    public void AMovedUnsavedTabWritesItsNewPathToTheRecoveryCopy()
    {
        using var f = new ViewModelFixture();
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        using var tab = new LazyPDF.App.Documents.DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), @"C:\old\a.pdf", "a.pdf", null, store, unsaved: true);

        tab.MoveTo(@"C:\new\a.pdf", null, null);
        store.Flush();

        Assert.Equal(@"C:\new\a.pdf", Assert.Single(store.List()).Meta.OriginalPath);
    }

    [Fact]
    public async Task ARestoredFileThatAsksForAPasswordKeepsItsRecoveryCopyUntilItIsOpen()
    {
        using var f = new ViewModelFixture();
        var store = CrashedLocked(f);
        f.Vm.CheckRecovery();

        await f.Vm.RestoreAsync();

        Assert.NotNull(f.Vm.PasswordRequest);
        Assert.Single(store.List());
    }

    [Fact]
    public async Task GivingUpAtThePasswordLeavesTheRecoveryCopyForTheNextStart()
    {
        using var f = new ViewModelFixture();
        var store = CrashedLocked(f);
        f.Vm.CheckRecovery();
        await f.Vm.RestoreAsync();

        f.Vm.CancelPending();

        Assert.Empty(f.Vm.Documents);
        Assert.Single(store.List());
        f.Vm.CheckRecovery();
        Assert.Single(f.Vm.RecoveryOffer!);
    }

    [Fact]
    public async Task OnceTheRestoredFileIsOpenOneRecoveryCopyRemains()
    {
        using var f = new ViewModelFixture();
        var store = CrashedLocked(f);
        f.Vm.CheckRecovery();
        var old = f.Vm.RecoveryOffer!.Single().Id;
        await f.Vm.RestoreAsync();

        await f.Vm.SubmitPasswordAsync("secret");

        var tab = Assert.Single(f.Vm.Documents);
        Assert.True(tab.IsDirty);
        store.Flush();
        Assert.Equal(tab.Id, Assert.Single(store.List()).Id);
        Assert.NotEqual(old, tab.Id);
    }

    [Fact]
    public async Task ARecoveryCopyThatCannotBeReadIsKept()
    {
        using var f = new ViewModelFixture();
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        store.Write(Guid.NewGuid(), "not a pdf"u8.ToArray(), new RecoveryMeta { Title = "bad.pdf", Saved = DateTimeOffset.Now });
        store.Flush();
        f.Vm.CheckRecovery();

        await f.Vm.RestoreAsync();

        Assert.Empty(f.Vm.Documents);
        Assert.True(f.Vm.Message!.IsError);
        Assert.Single(store.List());
    }

    [Fact]
    public async Task AReloadThatCannotReadTheFileKeepsTheTabAndItsChanges()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Mine");
        tab.Commit("Properties");
        using var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

        await f.Vm.ReloadAsync(tab);

        Assert.Same(tab, f.Vm.ActiveDocument);
        Assert.True(tab.IsDirty);
        Assert.False(tab.Renderer is FakeRenderer { Disposed: true });
        Assert.True(f.Vm.Message!.IsError);
        Assert.Contains(f.Vm.Recent, r => r.Path == path);
    }

    [Fact]
    public async Task AReloadOfAHalfWrittenFileKeepsTheTab()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        await f.SettledAsync();
        Touch(path, "%PDF-1.7\n"u8.ToArray());

        await f.Vm.ReloadAsync(tab);

        Assert.Same(tab, Assert.Single(f.Vm.Documents));
        Assert.True(f.Vm.Message!.IsError);
    }

    [Fact]
    public async Task AReloadOfAProtectedFileUsesThePasswordTheTabWasOpenedWith()
    {
        using var f = new ViewModelFixture();
        string path = Locked(f);
        await f.Vm.OpenAsync(path);
        await f.Vm.SubmitPasswordAsync("secret");
        var tab = f.Vm.ActiveDocument!;
        await f.SettledAsync();
        Touch(path, File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));

        await f.Vm.ReloadAsync(tab);

        Assert.Null(f.Vm.PasswordRequest);
        Assert.NotSame(tab, Assert.Single(f.Vm.Documents));
        Assert.Same(f.Vm.ActiveDocument, f.Vm.Documents.Single());
    }

    [Fact]
    public async Task SavingOverAFileAnotherProgramChangedStopsAndAsks()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Mine");
        tab.Commit("Properties");
        await f.SettledAsync();
        Touch(path, Pdfs.Text(pages: 3));

        bool saved = f.Vm.Save(tab);

        Assert.False(saved);
        Assert.Equal("File changed", f.Vm.Message!.Title);
        Assert.Equal(3, PdfDocument.Open(path).Pages.Count);
        Assert.True(tab.IsDirty);

        f.Vm.Message.Action!.Run();

        Assert.False(tab.IsDirty);
        Assert.Equal("Mine", DocumentMetadata.Read(PdfDocument.Open(path)).Title);
    }

    [Fact]
    public async Task SavingACleanTabOverAChangedFileAlsoAsks()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        await f.SettledAsync();
        Touch(path, Pdfs.Text(pages: 2));

        Assert.False(f.Vm.Save(f.Vm.ActiveDocument!));
        Assert.Equal(2, PdfDocument.Open(path).Pages.Count);
    }

    [Fact]
    public async Task SavingAFileThatWasDeletedWritesItAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        await f.SettledAsync();
        File.Delete(path);

        Assert.True(f.Vm.Save(f.Vm.ActiveDocument!));
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task ARestoredCopyOfAFileThatChangedWhileTheAppWasDownIsNotSavedOverIt()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");
        var seen = DiskStamp(path);
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        store.Write(Guid.NewGuid(), Pdfs.Text(), new RecoveryMeta
        {
            Title = "report.pdf", OriginalPath = path, Saved = DateTimeOffset.Now, OriginalWrite = seen.Write, OriginalLength = seen.Length,
        });
        store.Flush();
        Touch(path, Pdfs.Text(pages: 4));
        f.Vm.CheckRecovery();
        await f.Vm.RestoreAsync();

        Assert.False(f.Vm.Save(f.Vm.ActiveDocument!));
        Assert.Equal(4, PdfDocument.Open(path).Pages.Count);
    }

    private static (DateTime Write, long Length) DiskStamp(string path)
    {
        var info = new FileInfo(path);
        return (info.LastWriteTimeUtc, info.Length);
    }

    [Fact]
    public async Task AFileWithNoPagesIsRefusedAtOpen()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("empty.pdf", "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R /Size 3 >>\n%%EOF\n"u8.ToArray());

        await f.Vm.OpenAsync(path);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("Nothing to show", f.Vm.Message!.Title);
    }
}
