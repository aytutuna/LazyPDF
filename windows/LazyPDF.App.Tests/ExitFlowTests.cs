using Xunit;

namespace LazyPDF.App.Tests;

// Closing the window: every document with unsaved changes is asked about, one after the other.
public sealed class ExitFlowTests
{
    private static async Task Dirty(ViewModelFixture f, string name)
    {
        await f.Vm.OpenAsync(f.Pdf(name));
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, name);
        tab.Commit("Properties");
    }

    [Fact]
    public async Task WithNothingUnsavedTheWindowMayClose()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        Assert.True(f.Vm.RequestExit());
        Assert.All(f.Renderers, r => Assert.True(r.Disposed));
    }

    [Fact]
    public async Task TheFirstDocumentWithChangesIsAskedAboutAndTheWindowStaysOpen()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("clean.pdf"));
        await Dirty(f, "edited.pdf");

        Assert.False(f.Vm.RequestExit());

        Assert.Equal("edited.pdf", f.Vm.CloseQuestion?.Title);
        Assert.Equal("edited.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public async Task AnsweringEachQuestionEndsInTheExit()
    {
        using var f = new ViewModelFixture();
        await Dirty(f, "one.pdf");
        await Dirty(f, "two.pdf");
        int exits = 0;
        f.Vm.ExitRequested += (_, _) => exits++;

        Assert.False(f.Vm.RequestExit());
        f.Vm.Close(f.Vm.CloseQuestion!);
        Assert.Equal(0, exits);
        Assert.NotNull(f.Vm.CloseQuestion);
        f.Vm.Close(f.Vm.CloseQuestion!);

        Assert.Equal(1, exits);
        Assert.Null(f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task TheViewModelKnowsWhileAnExitIsInProgress()
    {
        using var f = new ViewModelFixture();
        await Dirty(f, "one.pdf");

        Assert.False(f.Vm.IsExiting);
        f.Vm.RequestExit();
        Assert.True(f.Vm.IsExiting);
        f.Vm.CancelClose();

        Assert.False(f.Vm.IsExiting);
        Assert.Null(f.Vm.CloseQuestion);
    }

    [Fact]
    public async Task CancellingTheQuestionCallsOffTheExit()
    {
        using var f = new ViewModelFixture();
        await Dirty(f, "one.pdf");
        await Dirty(f, "two.pdf");
        int exits = 0;
        f.Vm.ExitRequested += (_, _) => exits++;
        f.Vm.RequestExit();

        f.Vm.CancelClose();
        f.Vm.Close(f.Vm.ActiveDocument!);

        Assert.Equal(0, exits);
        Assert.Single(f.Vm.Documents);
    }
}
