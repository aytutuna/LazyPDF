using Xunit;

namespace LazyPDF.App.Tests;

// A job edits the document off the UI thread, so the window neither closes nor saves what it holds meanwhile.
public sealed class BusyCloseTests
{
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
    public async Task ClosingATabWaitsForTheJob()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        var (run, finish) = await StartJob(f.Vm);

        Assert.False(f.Vm.RequestClose(tab));

        Assert.Null(f.Vm.CloseQuestion);
        Assert.Equal("Still working", f.Vm.Message?.Title);
        Assert.Contains(tab, f.Vm.Documents);
        finish.SetResult();
        await run;
        Assert.False(f.Vm.RequestClose(tab));
        Assert.Same(tab, f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task ClosingTheWindowWaitsForTheJob()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        int exits = 0;
        f.Vm.ExitRequested += (_, _) => exits++;
        var (run, finish) = await StartJob(f.Vm);

        Assert.False(f.Vm.RequestExit());

        Assert.Equal(0, exits);
        Assert.All(f.Renderers, r => Assert.False(r.Disposed));
        finish.SetResult();
        await run;
        Assert.True(f.Vm.RequestExit());
    }

    [Fact]
    public async Task ASecondJobKeepsTheBusyBarWhenTheFirstEnds()
    {
        using var f = new ViewModelFixture();
        var (first, endFirst) = await StartJob(f.Vm);
        var (second, endSecond) = await StartJob(f.Vm);

        endFirst.SetResult();
        await first;
        Assert.True(f.Vm.IsBusy);

        endSecond.SetResult();
        await second;
        Assert.False(f.Vm.IsBusy);
    }
}
