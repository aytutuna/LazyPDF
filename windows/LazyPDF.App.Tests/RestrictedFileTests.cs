using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Core refuses a rewrite of a file that restricts itself with a PdfPermissionException; the tools say it in a sentence.
public sealed class RestrictedFileTests
{
    [Fact]
    public async Task AJobThatCoreRefusesShowsThePermissionsMessage()
    {
        using var f = new ViewModelFixture();

        await f.Vm.RunBusyAsync("Working", _ => throw new PdfPermissionException("The file restricts its permissions."));

        Assert.Equal(Problems.Restricted().Title, f.Vm.Message?.Title);
        Assert.Equal(Problems.Restricted().Text, f.Vm.Message?.Text);
        Assert.False(f.Vm.IsBusy);
    }

    [Fact]
    public async Task AFileSystemRefusalIsLeftToTheTool()
    {
        using var f = new ViewModelFixture();

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            f.Vm.RunBusyAsync("Working", _ => throw new UnauthorizedAccessException("Access to the path is denied.")));

        Assert.Null(f.Vm.Message);
        Assert.False(f.Vm.IsBusy);
    }

    [Fact]
    public Task AFileSystemRefusalInAToolIsNotTakenForTheFilesPermissions() => Sta.Run(async () =>
    {
        var host = new RecordingHost();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf");

        await ChangeGate.RunAsync(tab, host, "Save", () => throw new UnauthorizedAccessException("Access to the path is denied."));

        Assert.NotEqual(Problems.Restricted().Title, Assert.Single(host.Problems).Title);

        host.Problems.Clear();
        await ChangeGate.RunAsync(tab, host, "Save", () => throw new PdfPermissionException("The file restricts its permissions."));

        Assert.Equal(Problems.Restricted().Title, Assert.Single(host.Problems).Title);
    });

    [Fact]
    public void TheMessageSaysWhatToDo()
    {
        var problem = Problems.Restricted();

        Assert.Equal("This file cannot be changed", problem.Title);
        Assert.Contains("owner password", problem.Text);
    }
}
