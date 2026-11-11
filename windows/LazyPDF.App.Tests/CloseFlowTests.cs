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
        await f.SettledAsync();
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
    public async Task DiscardAllClosesEveryTabWithChangesAndCarriesOnTheExit()
    {
        using var f = new ViewModelFixture();
        for (int i = 0; i < 3; i++) await OpenDirty(f, $"{i}.pdf");
        bool exited = false;
        f.Vm.ExitRequested += (_, _) => exited = true;

        Assert.False(f.Vm.RequestExit());
        Assert.Equal(3, f.Vm.Unsettled);
        f.Vm.DiscardAll();

        Assert.True(exited);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task UnsettledCountsOnlyTabsWithChanges()
    {
        using var f = new ViewModelFixture();
        await OpenDirty(f, "a.pdf");
        await OpenDirty(f, "b.pdf");
        await f.Vm.OpenAsync(f.Pdf("c.pdf"));

        Assert.Equal(2, f.Vm.Unsettled);
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
    public async Task ATabWithMeasurementsWaitingIsAskedAboutAndStaysOpen()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMeasurements = 2;

        Assert.False(f.Vm.RequestClose(tab));

        Assert.Same(tab, f.Vm.CloseQuestion);
        Assert.False(tab.IsDirty);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task ExitAsksAboutWaitingMeasurementsToo()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMeasurements = 1;

        Assert.False(f.Vm.RequestExit());

        Assert.Same(tab, f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task ATabWithNoMeasurementsWaitingClosesAtOnce()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        tab.PendingMeasurements = 0;

        Assert.True(f.Vm.RequestClose(tab));

        Assert.Empty(f.Vm.Documents);
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
        Assert.IsType<IOException>(f.Vm.LastSaveError);
    }

    [Fact]
    public async Task AGoodSaveClearsTheLastSaveError()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        using (new FileStream(f.Dir.Sub("a.pdf"), FileMode.Open, FileAccess.Read, FileShare.None))
            f.Vm.Save(tab);

        Assert.True(f.Vm.Save(tab));

        Assert.Null(f.Vm.LastSaveError);
    }

    [Fact]
    public async Task ACloseQuestionForAMadeDocumentStaysUntilSaveAsWorks()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("pic.png", [1, 2, 3]));
        var tab = f.Vm.ActiveDocument!;
        tab.Commit("Properties");

        Assert.False(f.Vm.RequestClose(tab));
        Assert.True(AppViewModel.NeedsName(tab));
        Assert.Same(tab, f.Vm.CloseQuestion);
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
    public async Task ATabThatLeftTheStripWritesNothing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("a.pdf", Pdfs.Text(1, "fox")));
        var tab = f.Vm.ActiveDocument!;
        f.Vm.RequestClose(tab);
        string target = f.Dir.Sub("late.pdf");

        Assert.False(f.Vm.SaveAs(tab, target));
        Assert.False(f.Vm.SaveCopy(tab, target));

        Assert.False(System.IO.File.Exists(target));
        Assert.Equal("File reloaded", f.Vm.Message!.Title);
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
        await f.Vm.CheckDiskAsync();
        f.Vm.CloseRequested += (_, t) => f.Vm.RequestClose(t);
        f.Vm.RequestClose(tab);

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task SaveAnywayAfterBackingOutOfAnExitOnlyClosesTheTab()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
        File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
        await f.Vm.CheckDiskAsync();
        bool exited = false;
        f.Vm.ExitRequested += (_, _) => exited = true;
        int closed = 0;
        f.Vm.CloseRequested += (_, _) => closed++;
        f.Vm.CloseRequested += (_, t) => f.Vm.RequestClose(t);
        f.Vm.RequestExit();

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.False(exited);
        Assert.Equal(1, closed);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task SaveAnywayClosesATabWithMarksWithoutAskingAgain()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        tab.PendingMarks = 2;
        File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
        File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
        await f.Vm.CheckDiskAsync();
        f.Vm.CloseRequested += (_, t) => f.Vm.RequestClose(t);
        f.Vm.RequestClose(tab);

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.Empty(f.Vm.Documents);
        Assert.Null(f.Vm.CloseQuestion);
    }

    [Fact]
    public void SaveAnywayAfterBackingOutOfAnExitLeavesNoExitUnderWay()
    {
        // The check a tab switch starts must come back on the window's thread, as in the app.
        OneTabPerFileTests.OneThread.Run(async () =>
        {
            using var f = new ViewModelFixture();
            var tab = await OpenDirty(f);
            var other = await OpenDirty(f, "b.pdf");
            f.Vm.Save(other);
            File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
            File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
            await f.Vm.CheckDiskAsync();
            int exits = 0, asks = 0;
            f.Vm.ExitRequested += (_, _) => exits++;
            f.Vm.CloseRequested += (_, _) => asks++;
            f.Vm.RequestExit();

            Assert.False(f.Vm.Save(tab, closeAfter: true));
            f.Vm.CancelClose();
            f.Vm.Message!.Action!.Run();
            f.Vm.Close(other);

            Assert.Equal(1, asks);
            Assert.Equal(0, exits);
        });
    }

    [Fact]
    public async Task SaveAnywayKeepsTheMarksCountedWhenTheWindowLeavesTheTabOpen()
    {
        using var f = new ViewModelFixture();
        var tab = await OpenDirty(f);
        tab.PendingMarks = 2;
        File.WriteAllBytes(tab.Path!, Pdfs.Text(2));
        File.SetLastWriteTimeUtc(tab.Path!, DateTime.UtcNow.AddMinutes(10));
        await f.Vm.CheckDiskAsync();
        f.Vm.CloseRequested += (_, _) => { };
        f.Vm.RequestClose(tab);

        Assert.False(f.Vm.Save(tab, closeAfter: true));
        f.Vm.CancelClose();
        f.Vm.Message!.Action!.Run();

        Assert.Equal(2, tab.PendingMarks);
        Assert.False(f.Vm.RequestClose(tab));
    }

    [Fact]
    public async Task ClosingManyAsksAboutTheFirstTabWithChangesAndCarriesOnAfterTheAnswer()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("a.pdf"));
        var keep = f.Vm.ActiveDocument!;
        var dirty = await OpenDirty(f, "b.pdf");
        await f.Vm.OpenAsync(f.Pdf("c.pdf"));
        var clean = f.Vm.ActiveDocument!;

        f.Vm.RequestCloseMany([clean, dirty]);

        Assert.Same(dirty, f.Vm.CloseQuestion);
        Assert.Equal(2, f.Vm.Documents.Count());
        f.Vm.Close(dirty);
        Assert.Null(f.Vm.CloseQuestion);
        Assert.Same(keep, Assert.Single(f.Vm.Documents));
    }

    [Fact]
    public async Task ClosingManyAsksAboutEveryTabWithChanges()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("a.pdf"));
        var clean = f.Vm.ActiveDocument!;
        var first = await OpenDirty(f, "b.pdf");
        var second = await OpenDirty(f, "c.pdf");
        await f.Vm.OpenAsync(f.Pdf("d.pdf"));
        var keep = f.Vm.ActiveDocument!;

        f.Vm.RequestCloseMany([clean, first, second]);

        Assert.Same(first, f.Vm.CloseQuestion);
        f.Vm.Close(first);
        Assert.Same(second, f.Vm.CloseQuestion);
        f.Vm.Close(second);
        Assert.Null(f.Vm.CloseQuestion);
        Assert.Same(keep, Assert.Single(f.Vm.Documents));
    }

    [Fact]
    public async Task CancellingTheQuestionDropsTheRestOfTheTabsToClose()
    {
        using var f = new ViewModelFixture();
        var dirty = await OpenDirty(f, "a.pdf");
        await f.Vm.OpenAsync(f.Pdf("b.pdf"));
        var clean = f.Vm.ActiveDocument!;

        f.Vm.RequestCloseMany([dirty, clean]);
        f.Vm.CancelClose();
        f.Vm.Close(dirty);

        Assert.Same(clean, Assert.Single(f.Vm.Documents));
    }

    [Fact]
    public async Task ReopenClosedOpensTheFileClosedLast()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("a.pdf"));
        await f.Vm.OpenAsync(f.Pdf("b.pdf"));
        f.Vm.Close(f.Vm.ActiveDocument!);
        f.Vm.Close(f.Vm.ActiveDocument!);

        await f.Vm.ReopenClosedAsync();

        Assert.Equal("a.pdf", f.Vm.ActiveDocument!.Title);
        Assert.Single(f.Vm.ClosedFiles);
    }

    [Fact]
    public async Task ReopenClosedSkipsAFileThatIsGone()
    {
        using var f = new ViewModelFixture();
        string a = f.Pdf("a.pdf");
        await f.Vm.OpenAsync(a);
        string b = f.Pdf("b.pdf");
        await f.Vm.OpenAsync(b);
        f.Vm.Close(f.Vm.ActiveDocument!);
        f.Vm.Close(f.Vm.ActiveDocument!);
        File.Delete(a);

        await f.Vm.ReopenClosedAsync();

        Assert.Equal("b.pdf", f.Vm.ActiveDocument!.Title);
        Assert.Empty(f.Vm.ClosedFiles);
    }

    [Fact]
    public async Task ReopenClosedWithNothingLeftThereSaysItIsNotFound()
    {
        using var f = new ViewModelFixture();
        string a = f.Pdf("a.pdf");
        await f.Vm.OpenAsync(a);
        f.Vm.Close(f.Vm.ActiveDocument!);
        File.Delete(a);

        await f.Vm.ReopenClosedAsync();

        Assert.Empty(f.Vm.Documents);
        Assert.NotNull(f.Vm.Message);
        Assert.True(f.Vm.Message!.IsError);
    }

    [Fact]
    public async Task ClosedFilesKeepTheLastTenWithoutRepeats()
    {
        using var f = new ViewModelFixture();
        for (int i = 0; i < 12; i++)
        {
            await f.Vm.OpenAsync(f.Pdf($"{i}.pdf"));
            f.Vm.Close(f.Vm.ActiveDocument!);
        }
        await f.Vm.OpenAsync(f.Vm.ClosedFiles[^1]);
        f.Vm.Close(f.Vm.ActiveDocument!);

        Assert.Equal(10, f.Vm.ClosedFiles.Count);
        Assert.Equal(10, f.Vm.ClosedFiles.Distinct().Count());
        Assert.EndsWith("11.pdf", f.Vm.ClosedFiles[^1]);
    }
}
