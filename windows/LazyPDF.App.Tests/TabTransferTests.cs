using LazyPDF.App.Documents;
using Xunit;

namespace LazyPDF.App.Tests;

// A tab moves between two windows as the same object: its edits, undo history, recovery copy and password go along.
public sealed class TabTransferTests
{
    private static async Task<DocumentTab> OpenAsync(ViewModelFixture f, string name)
    {
        await f.Vm.OpenAsync(f.Pdf(name));
        return f.Vm.ActiveDocument!;
    }

    private static void Edit(DocumentTab tab, string title = "Changed")
    {
        Pdfs.Retitle(tab.Session, title);
        tab.Commit("Properties");
    }

    private static async Task<(Task Run, TaskCompletionSource Finish)> StartJob(AppViewModel vm)
    {
        var started = new TaskCompletionSource();
        var finish = new TaskCompletionSource();
        var run = vm.RunBusyAsync("Working", async _ =>
        {
            started.SetResult();
            await finish.Task;
        });
        await started.Task;
        return (run, finish);
    }

    [Fact]
    public async Task TheSameTabArrivesWithItsHistoryAndWindowStateAndIsNotClosed()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        Edit(tab);
        tab.Rotation = 90;
        tab.Zoom = 1.5;
        var renderer = w.A.Renderers.Single();

        Assert.True(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Same(tab, w.B.Vm.ActiveDocument);
        Assert.Equal([HomeTab.Instance], w.A.Vm.Strip);
        Assert.True(w.A.Vm.IsHome);
        Assert.Same(w.B.Vm, w.Registry.Find(tab.Id));
        Assert.Equal("Properties", w.B.Vm.UndoLabel);
        Assert.False(renderer.Disposed);
        Assert.Empty(w.A.Vm.ClosedFiles);
        Assert.Equal((90, 1.5), (tab.Rotation, tab.Zoom));
        w.B.Vm.Undo();
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public async Task TheSourceFallsToTheNeighbourWhenTheActiveTabLeaves()
    {
        using var w = new TwoWindows();
        var first = await OpenAsync(w.A, "a.pdf");
        var second = await OpenAsync(w.A, "b.pdf");
        var third = await OpenAsync(w.A, "c.pdf");
        w.A.Vm.ActiveTab = second;

        w.Registry.Transfer(second, w.A.Vm, w.B.Vm, 1);

        Assert.Equal([first, third], w.A.Vm.Documents);
        Assert.Same(third, w.A.Vm.ActiveDocument);
    }

    [Fact]
    public async Task TheRecoveryCopyOfAnUnsavedTabStaysAfterTheMove()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        Edit(tab);
        w.Recovery.Flush();
        Assert.Equal(tab.Id, Assert.Single(w.Recovery.List()).Id);

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);
        w.Recovery.Flush();

        var entry = Assert.Single(w.Recovery.List());
        Assert.Equal(tab.Id, entry.Id);
        Assert.True(File.Exists(entry.PdfPath));
    }

    [Fact]
    public async Task OnlyTheWindowThatHoldsTheTabIsToldAboutItsChanges()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);
        int a = 0, b = 0;
        w.A.Vm.PropertyChanged += (_, _) => a++;
        w.B.Vm.PropertyChanged += (_, _) => b++;

        Edit(tab);

        Assert.Equal(0, a);
        Assert.True(b > 0);
    }

    [Fact]
    public async Task MarksAndMeasurementsTravelWithTheTab()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        tab.PendingMarks = 2;
        tab.PendingMeasurements = 1;

        Assert.True(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Equal((2, 1), (tab.PendingMarks, tab.PendingMeasurements));
        Assert.Equal(1, w.B.Vm.Unsettled);
        Assert.Equal(0, w.A.Vm.Unsettled);
    }

    [Fact]
    public async Task APasswordOpenedAndAReadOnlyFileKeepTheirState()
    {
        using var w = new TwoWindows();
        string locked = w.A.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        await w.A.Vm.OpenAsync(locked);
        await w.A.Vm.SubmitPasswordAsync("secret");
        var tab = w.A.Vm.ActiveDocument!;
        tab.ReadOnly = true;

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);

        Assert.Equal("secret", tab.Password);
        Assert.True(tab.ReadOnly);
        Assert.True(AppViewModel.NeedsName(tab));
        Assert.Null(w.B.Vm.PasswordRequest);
    }

    [Fact]
    public async Task AMadeDocumentStaysUnsavedWithItsRecoveryCopy()
    {
        using var w = new TwoWindows();
        Assert.True(await w.A.Vm.OpenNewAsync(Pdfs.Text(), "Made.pdf"));
        var tab = w.A.Vm.ActiveDocument!;
        w.Recovery.Flush();

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);
        w.Recovery.Flush();

        Assert.True(tab.IsDirty);
        Assert.Null(tab.Path);
        Assert.Single(w.Recovery.List());
    }

    [Fact]
    public async Task ADropAfterTheLastTabAndAPositionPastItLandLast()
    {
        using var w = new TwoWindows();
        await OpenAsync(w.B, "x.pdf");
        await OpenAsync(w.B, "y.pdf");
        var one = await OpenAsync(w.A, "a.pdf");
        var two = await OpenAsync(w.A, "b.pdf");

        w.Registry.Transfer(one, w.A.Vm, w.B.Vm, w.B.Vm.Strip.Count);
        w.Registry.Transfer(two, w.A.Vm, w.B.Vm, 99);

        Assert.Equal([one, two], w.B.Vm.Documents.TakeLast(2));
        Assert.Same(two, w.B.Vm.ActiveDocument);
    }

    [Fact]
    public async Task ADropAtTheStartLandsAfterHome()
    {
        using var w = new TwoWindows();
        await OpenAsync(w.B, "x.pdf");
        var tab = await OpenAsync(w.A, "a.pdf");

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 0);

        Assert.Same(tab, w.B.Vm.Documents.First());
        Assert.Same(HomeTab.Instance, w.B.Vm.Strip[0]);
    }

    [Fact]
    public async Task ANoticeAboutTheMovedTabDoesNotStayBehind()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        w.A.Vm.ShowNotice("File is read-only", "x");

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);

        Assert.Null(w.A.Vm.Message);
    }

    [Fact]
    public async Task ASaveAnywayButtonCannotReachATabThatLeft()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        w.A.Vm.ShowNotice("File changed", "x", new NoticeAction("Save anyway", () => { }));

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);

        Assert.Null(w.A.Vm.Message?.Action);
    }

    [Fact]
    public async Task ANoticeAboutAnotherTabStays()
    {
        using var w = new TwoWindows();
        var other = await OpenAsync(w.A, "a.pdf");
        var tab = await OpenAsync(w.A, "b.pdf");
        w.A.Vm.ActiveTab = other;
        w.A.Vm.ShowNotice("File is read-only", "x");

        w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1);

        Assert.Equal("File is read-only", w.A.Vm.Message?.Title);
    }

    [Fact]
    public void TheHomeTabCannotMove()
    {
        using var w = new TwoWindows();

        Assert.False(w.A.Vm.CanRelease(HomeTab.Instance, out var reason));
        Assert.NotNull(reason);
    }

    [Fact]
    public async Task ATabCannotLeaveWhileAJobRuns()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        var (run, finish) = await StartJob(w.A.Vm);

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Contains(tab, w.A.Vm.Documents);
        Assert.Empty(w.B.Vm.Documents);
        Assert.Equal("Tab not moved", w.A.Vm.Message?.Title);
        finish.SetResult();
        await run;
    }

    [Fact]
    public async Task ATabBeingClosedCannotLeave()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        Edit(tab);
        Assert.False(w.A.Vm.RequestClose(tab));

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Contains(tab, w.A.Vm.Documents);
        Assert.Same(tab, w.A.Vm.CloseQuestion);
        Assert.Empty(w.B.Vm.Documents);
    }

    [Fact]
    public async Task ATabQueuedToCloseCannotLeave()
    {
        using var w = new TwoWindows();
        var first = await OpenAsync(w.A, "a.pdf");
        var second = await OpenAsync(w.A, "b.pdf");
        Edit(first);
        w.A.Vm.RequestCloseMany([first, second]);

        Assert.False(w.A.Vm.CanRelease(second, out var reason));
        Assert.NotNull(reason);
    }

    [Fact]
    public async Task ATabBeingReloadedCannotLeave()
    {
        using var w = new TwoWindows();
        await w.A.Vm.OpenAsync(w.A.Pdf("a.pdf"));
        var tab = w.A.Vm.ActiveDocument!;
        var reload = w.A.Vm.TryReloadAsync(tab);

        Assert.False(w.A.Vm.CanRelease(tab, out var reason));
        Assert.NotNull(reason);
        await reload;
    }

    [Fact]
    public async Task ABusyTargetRefusesAndBothStripsStay()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        var (run, finish) = await StartJob(w.B.Vm);

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Same(tab, w.A.Vm.ActiveDocument);
        Assert.Empty(w.B.Vm.Documents);
        finish.SetResult();
        await run;
    }

    [Fact]
    public async Task ATargetWithAQuestionOrAPasswordPromptRefuses()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        var dirty = await OpenAsync(w.B, "b.pdf");
        Edit(dirty);
        w.B.Vm.RequestClose(dirty);
        Assert.False(w.B.Vm.CanAdopt(true, out _));
        w.B.Vm.CancelClose();
        Assert.True(w.B.Vm.CanAdopt(true, out _));
        await w.B.Vm.OpenAsync(w.B.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf"))));
        Assert.False(w.B.Vm.CanAdopt(true, out _));

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Contains(tab, w.A.Vm.Documents);
        Assert.DoesNotContain(tab, w.B.Vm.Documents);
    }

    [Fact]
    public async Task AWindowThatIsNotFreeRefuses()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1, targetFree: false));

        Assert.Contains(tab, w.A.Vm.Documents);
        Assert.Equal("Tab not moved", w.A.Vm.Message?.Title);
    }

    [Fact]
    public async Task ATabThatAnotherWindowHoldsIsNotMovedByTheWrongOne()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");

        Assert.False(w.Registry.Transfer(tab, w.B.Vm, w.A.Vm, 1));

        Assert.Single(w.A.Vm.Documents);
    }

    [Fact]
    public async Task ATargetThatFailsToDrawGivesTheTabBackAtItsPlace()
    {
        using var w = new TwoWindows();
        var first = await OpenAsync(w.A, "a.pdf");
        var tab = await OpenAsync(w.A, "b.pdf");
        var last = await OpenAsync(w.A, "c.pdf");
        w.A.Vm.ActiveTab = first;
        w.B.Vm.PropertyChanged += (_, _) =>
        {
            if (w.B.Vm.Strip.Contains(tab)) throw new InvalidOperationException("cannot draw");
        };

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Equal([first, tab, last], w.A.Vm.Documents);
        Assert.Same(first, w.A.Vm.ActiveDocument);
        Assert.Empty(w.B.Vm.Documents);
        Assert.Same(w.A.Vm, w.Registry.Find(tab.Id));
        Assert.Single(w.Registry.Models.Where(m => m.Strip.Contains(tab)));
        Assert.False(w.A.Renderers[1].Disposed);
        Assert.Equal("Tab not moved", w.A.Vm.Message?.Title);
    }

    [Fact]
    public async Task ASourceThatFailsToDrawAfterReleaseStillEndsWithTheTabInOneStrip()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        bool failed = false;
        w.A.Vm.PropertyChanged += (_, _) =>
        {
            if (failed || w.A.Vm.Strip.Contains(tab)) return;
            failed = true;
            throw new InvalidOperationException("cannot draw");
        };

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Single(w.Registry.Models.Where(m => m.Strip.Contains(tab)));
        Assert.Contains(tab, w.A.Vm.Documents);
    }

    [Fact]
    public async Task AFailedMoveLeavesTheTargetWithItsActiveTabAndItsPrompt()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        await OpenAsync(w.B, "b.pdf");
        var shown = await OpenAsync(w.B, "c.pdf");
        var other = w.B.Vm.Documents.First();
        w.B.Vm.ActiveTab = other;
        w.B.Vm.ShowNotice("Changed on disk", "Reload?", new NoticeAction("Reload", () => { }));
        w.B.Vm.PropertyChanged += (_, _) =>
        {
            if (w.B.Vm.Strip.Contains(tab)) throw new InvalidOperationException("cannot draw");
        };

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Same(other, w.B.Vm.ActiveDocument);
        Assert.Equal([other, shown], w.B.Vm.Documents);
        Assert.Equal("Reload", w.B.Vm.Message?.Action?.Text);
    }

    [Fact]
    public async Task ATargetStripThatThrowsOnTheInsertEndsWithTheTabInTheSourceSubscribedOnce()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        int changes = Notifications(w.A.Vm, tab);
        w.B.Vm.Strip.CollectionChanged += (_, e) =>
        {
            if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Add) throw new InvalidOperationException("strip");
        };

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Single(w.Registry.Models.Where(m => m.Strip.Contains(tab)));
        Assert.Same(w.A.Vm, w.Registry.Find(tab.Id));
        Assert.Equal(changes, Notifications(w.A.Vm, tab));
    }

    [Fact]
    public async Task ASourceStripThatThrowsOnTheRemovalEndsWithTheTabInTheSourceSubscribedOnce()
    {
        using var w = new TwoWindows();
        var tab = await OpenAsync(w.A, "a.pdf");
        int changes = Notifications(w.A.Vm, tab);
        w.A.Vm.Strip.CollectionChanged += (_, e) =>
        {
            if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Remove) throw new InvalidOperationException("strip");
        };

        Assert.False(w.Registry.Transfer(tab, w.A.Vm, w.B.Vm, 1));

        Assert.Single(w.Registry.Models.Where(m => m.Strip.Contains(tab)));
        Assert.Contains(tab, w.A.Vm.Documents);
        Assert.Equal(changes, Notifications(w.A.Vm, tab));
    }

    [Fact]
    public async Task ReleasingTheActiveTabLeavesItsNeighbourActiveAndNothingSubscribed()
    {
        using var w = new TwoWindows();
        var first = await OpenAsync(w.A, "a.pdf");
        var tab = await OpenAsync(w.A, "b.pdf");
        var last = await OpenAsync(w.A, "c.pdf");
        w.A.Vm.ActiveTab = tab;
        int seen = 0;
        w.A.Vm.PropertyChanged += (_, _) => seen++;

        w.A.Vm.Release(tab);
        seen = 0;
        Edit(tab);

        Assert.Same(last, w.A.Vm.ActiveDocument);
        Assert.Equal(0, seen);
        Assert.Equal([first, last], w.A.Vm.Documents);
    }

    // How many times the view model hears of one change to the tab.
    private static int Notifications(AppViewModel vm, DocumentTab tab)
    {
        int seen = 0;
        void Count(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => seen++;
        vm.PropertyChanged += Count;
        Edit(tab, Guid.NewGuid().ToString());
        vm.PropertyChanged -= Count;
        return seen;
    }
}
