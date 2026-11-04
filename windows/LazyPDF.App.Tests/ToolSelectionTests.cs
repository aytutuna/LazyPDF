using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using Xunit;

namespace LazyPDF.App.Tests;

// The tool and the side panel in use, the appearance and the busy bar: the window state that is not a document.
[Collection("Application")]
public sealed class ToolSelectionTests
{
    [Fact]
    public void PickingAToolSelectsItAndPickingItAgainClosesIt()
    {
        using var f = new ViewModelFixture();

        f.Vm.SelectTool("stamps");
        Assert.Equal("stamps", f.Vm.ActiveToolId);
        Assert.Equal(ToolGroup.Edit, f.Vm.ActiveTool?.Group);

        f.Vm.SelectTool("stamps");
        Assert.Null(f.Vm.ActiveToolId);
    }

    [Fact]
    public void AnotherToolReplacesTheFirst()
    {
        using var f = new ViewModelFixture();
        f.Vm.SelectTool("stamps");

        f.Vm.SelectTool("redact");

        Assert.Equal("redact", f.Vm.ActiveToolId);
    }

    [Fact]
    public void AnUnknownToolIsIgnored()
    {
        using var f = new ViewModelFixture();
        f.Vm.SelectTool("stamps");

        f.Vm.SelectTool("nothing");

        Assert.Equal("stamps", f.Vm.ActiveToolId);
    }

    [Fact]
    public void ThePagesPanelIsOpenToStartWithAndTheRailRemembersTheChoice()
    {
        using var f = new ViewModelFixture();
        Assert.Equal("pages", f.Vm.SidePanelId);

        f.Vm.SetSidePanel("layers");

        var again = new AppViewModel(() => new FakeRenderer(), new FakeCodec(), new FakeFonts(), new FakeSisters(), f.Dir.Sub("settings"), f.Dir.Sub("recovery"), f.Dir.Sub("print"));
        Assert.Equal("layers", again.SidePanelId);
    }

    [Fact]
    public void PickingTheOpenPanelCollapsesTheRailAndTheToggleBringsItBack()
    {
        using var f = new ViewModelFixture();
        f.Vm.SetSidePanel("pages");
        Assert.Equal("", f.Vm.SidePanelId);

        f.Vm.ToggleSidePanel();
        Assert.Equal("pages", f.Vm.SidePanelId);

        f.Vm.SetSidePanel("search");
        f.Vm.ToggleSidePanel();
        Assert.Equal("", f.Vm.SidePanelId);
        f.Vm.ToggleSidePanel();
        Assert.Equal("search", f.Vm.SidePanelId);
    }

    [Fact]
    public Task TheAppearanceIsKept() => Sta.Run(() =>
    {
        using var f = new ViewModelFixture();

        f.Vm.SetAppearance(AppAppearance.Dark);

        Assert.Equal(AppAppearance.Dark, ThemeService.Appearance);
        Assert.Equal(AppAppearance.Dark, AppPreferencesStore.Load(f.Dir.Sub("settings")).Appearance);
        ThemeService.Apply(AppAppearance.System);
        return Task.CompletedTask;
    });

    [Fact]
    public async Task TheBusyBarShowsWhileWorkRunsAndCancelEndsIt()
    {
        using var f = new ViewModelFixture();
        var started = new TaskCompletionSource();
        var seen = new List<bool>();
        f.Vm.PropertyChanged += (_, _) => seen.Add(f.Vm.IsBusy);

        var run = f.Vm.RunBusyAsync("Reading page 2 of 9", async token =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        });
        await started.Task;
        Assert.True(f.Vm.IsBusy);
        Assert.Equal("Reading page 2 of 9", f.Vm.BusyText);

        f.Vm.CancelBusy();
        await run;

        Assert.False(f.Vm.IsBusy);
        Assert.Equal("Cancelled.", f.Vm.StatusFull);
        Assert.Contains(true, seen);
    }

    [Fact]
    public async Task TheBusyBarClearsWhenTheWorkFails()
    {
        using var f = new ViewModelFixture();

        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Vm.RunBusyAsync("Working", _ => throw new InvalidOperationException()));

        Assert.False(f.Vm.IsBusy);
    }

    [Fact]
    public void TheStatusLineIsShortAndTheSentenceIsKept()
    {
        using var f = new ViewModelFixture();

        f.Vm.SetStatus("Saved report.pdf. The old version is in the file's history.");

        Assert.Equal("Saved report.pdf", f.Vm.StatusShort);
        Assert.Equal("Saved report.pdf. The old version is in the file's history.", f.Vm.StatusFull);
    }

    [Fact]
    public void TheInfoBarShowsAProblemAndIsDismissed()
    {
        using var f = new ViewModelFixture();

        f.Vm.ShowProblem(new Documents.Problem("Not saved", "Check the disk."));
        Assert.True(f.Vm.Message?.IsError);

        f.Vm.ShowNotice("File changed", "By another program.", new NoticeAction("Reload", () => { }));
        Assert.False(f.Vm.Message?.IsError);
        Assert.Equal("Reload", f.Vm.Message?.Action?.Text);

        f.Vm.DismissMessage();
        Assert.Null(f.Vm.Message);
    }
}
