using LazyPDF.App.Documents;
using Xunit;

namespace LazyPDF.App.Tests;

// Closing and saving through the view model: unsaved changes are asked about, the strip keeps Home first.
public sealed class CloseFlowTests
{
    private static async Task<DocumentTab> OpenDirty(ViewModelFixture f, string name = "a.pdf")
    {
        await f.Vm.OpenAsync(f.Pdf(name));
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");
        return tab;
    }

    [Fact]
    public async Task ACleanTabClosesAtOnce()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;

        Assert.True(f.Vm.RequestClose(tab));

        Assert.Empty(f.Vm.Documents);
        Assert.True(f.Vm.IsHome);
        Assert.True(f.Renderers[0].Disposed);
    }

    [Fact]
    public async Task ATabWithChangesIsAskedAboutAndStaysOpen()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);

        Assert.False(f.Vm.RequestClose(tab));

        Assert.Same(tab, f.Vm.CloseQuestion);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task ATabWithRedactionMarksWaitingIsAskedAboutAndStaysOpen()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMarks = 3;

        Assert.False(f.Vm.RequestClose(tab));

        Assert.Same(tab, f.Vm.CloseQuestion);
        Assert.False(tab.IsDirty);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task ExitAsksAboutAnUnappliedRedactionMarkToo()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMarks = 1;

        Assert.False(f.Vm.RequestExit());

        Assert.Same(tab, f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task CancellingTheQuestionKeepsTheDocument()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        f.Vm.RequestClose(tab);

        f.Vm.CancelClose();

        Assert.Null(f.Vm.CloseQuestion);
        Assert.Single(f.Vm.Documents);
        Assert.True(tab.IsDirty);
    }

    [Fact]
    public async Task SavingThenClosingWritesTheFileAndEndsTheTab()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        f.Vm.RequestClose(tab);

        Assert.True(f.Vm.Save(tab));
        f.Vm.Close(tab);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("Changed", LazyPDF.Core.DocumentMetadata.Read(LazyPDF.Core.PdfDocument.Open(f.Dir.Sub("a.pdf"))).Title);
        Assert.Null(f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task DiscardingClosesWithoutWriting()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        byte[] before = File.ReadAllBytes(path);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");
        f.Vm.RequestClose(tab);

        f.Vm.Close(tab);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task ClosingTheActiveTabShowsItsNeighbour()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf"), f.Pdf("c.pdf")]);
        var tabs = f.Vm.Documents.ToList();
        f.Vm.ActiveTab = tabs[1];

        f.Vm.Close(tabs[1]);

        Assert.Equal("c.pdf", f.Vm.ActiveDocument?.Title);
        f.Vm.Close(tabs[2]);
        Assert.Equal("a.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public async Task AFailedSaveSaysSoAndKeepsTheChanges()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        using var lockIt = new FileStream(f.Dir.Sub("a.pdf"), FileMode.Open, FileAccess.Read, FileShare.None);

        Assert.False(f.Vm.Save(tab));

        Assert.Equal("Not saved", f.Vm.Message?.Title);
        Assert.True(tab.IsDirty);
    }

    [Fact]
    public async Task SaveAsGivesAMadeDocumentItsFile()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("pic.png", [1, 2, 3]));
        var tab = f.Vm.ActiveDocument!;
        string target = f.Dir.Sub("pic.pdf");

        Assert.True(f.Vm.SaveAs(tab, target));

        Assert.Equal("pic.pdf", tab.Title);
        Assert.False(tab.IsDirty);
        Assert.Contains(f.Vm.Recent, r => r.Path == target);
        Assert.Contains("pic.pdf", f.Vm.StatusFull);
    }

    [Fact]
    public async Task SaveCompactWritesTheDocumentAnewAndForgetsItsHistory()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);

        Assert.True(f.Vm.SaveCompact(tab, f.Dir.Sub("small.pdf")));

        Assert.False(f.Vm.CanUndo);
        Assert.Equal("small.pdf", tab.Title);
        Assert.Equal("Saved compact", f.Vm.Message?.Title);
        Assert.False(f.Vm.Message!.IsError);
    }

    [Fact]
    public async Task TabsCanBeMovedButHomeStaysFirst()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf"), f.Pdf("c.pdf")]);
        var tabs = f.Vm.Documents.ToList();

        f.Vm.MoveTab(tabs[2], 1);
        Assert.Equal(["c.pdf", "a.pdf", "b.pdf"], f.Vm.Documents.Select(d => d.Title));

        f.Vm.MoveTab(tabs[0], 0);
        Assert.Same(HomeTab.Instance, f.Vm.Strip[0]);
        Assert.Equal(["a.pdf", "c.pdf", "b.pdf"], f.Vm.Documents.Select(d => d.Title));

        f.Vm.MoveTab(tabs[1], 99);
        Assert.Equal("b.pdf", f.Vm.Documents.Last().Title);
    }

    [Fact]
    public async Task HomeCannotBeClosedOrMoved()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf")]);

        Assert.False(HomeTab.Instance.CanClose);
        Assert.Equal(0, f.Vm.Strip.IndexOf(HomeTab.Instance));
    }

    [Fact]
    public async Task UndoAndRedoActOnTheActiveDocument()
    {
        using var f = new ViewModelFixture();
        await OpenDirty(f);
        Assert.True(f.Vm.CanUndo);
        Assert.Equal("Properties", f.Vm.UndoLabel);

        f.Vm.Undo();
        Assert.False(f.Vm.CanUndo);
        Assert.True(f.Vm.CanRedo);

        f.Vm.Redo();
        Assert.True(f.Vm.CanUndo);
    }

    [Fact]
    public void UndoWithNoDocumentDoesNothing()
    {
        using var f = new ViewModelFixture();

        f.Vm.Undo();
        f.Vm.Redo();

        Assert.False(f.Vm.CanUndo);
    }

    [Fact]
    public async Task SaveAnywayFromTheCloseQuestionClosesTheTab()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
        File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
        f.Vm.CheckDisk();
        f.Vm.RequestClose(tab);

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task SaveAnywayDuringAnExitGoesOnWithTheExit()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
        File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
        f.Vm.CheckDisk();
        bool exited = false;
        f.Vm.ExitRequested += (_, _) => exited = true;
        f.Vm.RequestExit();

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.True(exited);
    }
}
