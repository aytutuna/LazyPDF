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
        Assert.Equal("Cancelled.", f.Vm.StatusFull);
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
}
