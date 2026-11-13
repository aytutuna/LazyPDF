using LazyPDF.App.Tools;
using Xunit;

namespace LazyPDF.App.Tests;

// What a tool panel gets from the window: the busy bar, messages, new tabs, and the window hearing of its commits.
public sealed class ToolHostTests
{
    [Fact]
    public async Task ABusyRunShowsTheBarAndCanBeCancelled()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        var started = new TaskCompletionSource();

        var run = host.RunBusyAsync("Working", async token =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        });
        await started.Task;
        Assert.True(f.Vm.IsBusy);
        Assert.Equal("Working", f.Vm.BusyText);
        f.Vm.CancelBusy();
        await run;

        Assert.False(f.Vm.IsBusy);
        Assert.Equal("Canceled.", f.Vm.StatusFull);
    }

    [Fact]
    public async Task OpeningAToolKeepsItOpenAndSaysSo()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());
        var raised = 0;
        f.Vm.ToolOpened += (_, _) => raised++;

        host.OpenTool("ocr");
        host.OpenTool("ocr");

        Assert.Equal("ocr", f.Vm.ActiveToolId);
        Assert.Equal(2, raised);
    }

    [Fact]
    public async Task AToolOpenedToReturnHandsBackTheToolOnce()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());

        host.OpenToolReturning("ocr", "export");

        Assert.Equal("ocr", f.Vm.ActiveToolId);
        Assert.Equal("export", host.TakeReturnTool());
        Assert.Null(host.TakeReturnTool());
    }

    [Fact]
    public async Task PickingAnotherToolForgetsTheToolToReturnTo()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());

        host.OpenToolReturning("ocr", "export");
        f.Vm.SelectTool("redact");

        Assert.Null(host.TakeReturnTool());
    }

    [Fact]
    public async Task OpeningAToolThatDoesNotExistChangesNothing()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());
        var raised = false;
        f.Vm.ToolOpened += (_, _) => raised = true;

        host.OpenTool("nothing");

        Assert.Null(f.Vm.ActiveToolId);
        Assert.False(raised);
    }

    [Fact]
    public void OpeningAToolWithNoDocumentChangesNothing()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;

        host.OpenTool("ocr");

        Assert.Null(f.Vm.ActiveToolId);
    }

    [Fact]
    public async Task OpeningAToolWhileBusyChangesNothing()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());
        var started = new TaskCompletionSource();
        var run = host.RunBusyAsync("Working", async token =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        });
        await started.Task;

        host.OpenTool("ocr");
        f.Vm.CancelBusy();
        await run;

        Assert.Null(f.Vm.ActiveToolId);
    }

    [Fact]
    public async Task ASignatureFieldIsHandedOverOnce()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;
        await f.Vm.OpenAsync(f.Pdf());

        host.OpenSigning("Signature1");

        Assert.Equal("certificates", f.Vm.ActiveToolId);
        Assert.Equal("Signature1", host.TakeSigningField());
        Assert.Null(host.TakeSigningField());
    }

    [Fact]
    public void AToolCanSayWhatWentWrong()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;

        host.ShowProblem(new("Not combined", "The second file is locked."));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Not combined", f.Vm.Message.Title);
    }

    [Fact]
    public async Task AResultOpensAsANewDocumentThatNeedsAName()
    {
        using var f = new ViewModelFixture();
        IToolHost host = f.Vm;

        await host.OpenNewAsync(Pdfs.Text(2), "Combined.pdf");

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal("Combined.pdf", tab.Title);
        Assert.Equal(2, tab.PageCount);
        Assert.True(tab.IsDirty);
        Assert.True(AppViewModel.NeedsName(tab));
    }

    [Fact]
    public async Task ACommitReachesTheViewModelSoUndoIsOffered()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        int notified = 0;
        f.Vm.PropertyChanged += (_, _) => notified++;
        Assert.False(f.Vm.CanUndo);

        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");

        Assert.True(notified > 0);
        Assert.True(f.Vm.CanUndo);
        Assert.Equal("Properties", f.Vm.UndoLabel);
    }

    [Fact]
    public async Task AClosedTabNoLongerNotifiesTheViewModel()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        f.Vm.Close(tab);
        int notified = 0;
        f.Vm.PropertyChanged += (_, _) => notified++;

        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");

        Assert.Equal(0, notified);
    }

    [Fact]
    public async Task ANoticeGoesWithItsTabButAProblemStays()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("a.pdf"));
        var first = f.Vm.ActiveDocument!;
        await f.Vm.OpenAsync(f.Pdf("b.pdf"));
        f.Vm.ActiveTab = first;

        f.Vm.ShowNotice("Done", "Something happened.");
        f.Vm.ActiveTab = f.Vm.Documents.Last();
        Assert.Null(f.Vm.Message);

        f.Vm.ShowProblem(new("Not saved", "The disk is full."));
        f.Vm.ActiveTab = first;
        Assert.True(f.Vm.Message!.IsError);
    }

    [Fact]
    public async Task UndoClearsANotice()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Changed");
        tab.Commit("Properties");

        f.Vm.ShowNotice("Done", "Something happened.");
        f.Vm.Undo();

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task ANoticeMadeRightAfterOpeningStaysOnTheNewTab()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        f.Vm.ShowNotice("Done", "Something happened.");

        Assert.NotNull(f.Vm.Message);
    }
}
