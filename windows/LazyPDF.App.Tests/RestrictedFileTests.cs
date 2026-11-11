using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Viewer;
using System.Windows;
using System.Windows.Automation;
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
    public Task CopyingIsRefusedOnlyWhenTheFileForbidsIt() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);
        using var forbidden = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy)), new FakeRenderer(), null, "a.pdf");
        using var allowed = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.Copy)), new FakeRenderer(), null, "b.pdf");

        Assert.True(viewer.CanCopy);
        viewer.Show(forbidden);
        Assert.False(viewer.CanCopy);
        viewer.Show(allowed);
        Assert.True(viewer.CanCopy);
        return Task.CompletedTask;
    });

    [Fact]
    public Task CopyingWithNothingSelectedSaysNothing() => Sta.Run(async () =>
    {
        var viewer = new PageViewer(null);
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy)), new FakeRenderer(), null, "a.pdf");
        viewer.Show(tab);

        await viewer.CopySelectionAsync();

        Assert.Equal(Visibility.Collapsed, ((FrameworkElement)viewer.FindName("LinkCard")).Visibility);
    });

    [Fact]
    public Task CopyingASelectionIsRefusedAndTheFindBoxStaysEmpty() => Sta.Run(async () =>
    {
        var viewer = new PageViewer(null);
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy)), new FakeRenderer(), null, "a.pdf");
        viewer.Show(tab);
        viewer.SelectAll();
        await viewer.GetSelectionAsync();
        Clipboard.SetText("before");

        await viewer.CopySelectionAsync();
        viewer.ShowFind();

        Assert.Equal("before", Clipboard.GetText());
        AssertCard(viewer, "The owner of this file does not allow copying.");
        Assert.Equal("", ((FindBar)viewer.FindName("Find")).Query.Text);
    });

    [Theory]
    [InlineData("SetOCGState", "This link shows or hides a layer. Use the Layers panel for that.")]
    [InlineData("GoToE", "This link goes to a file inside this file, which Lazy PDF does not open from here.")]
    [InlineData("Movie", "This link plays sound, video or 3D content, which Lazy PDF does not do.")]
    [InlineData("Hide", "This link shows or hides part of the page, which Lazy PDF does not do.")]
    [InlineData("Thread", "This link cannot be followed.")]
    public Task ALinkThatCannotBeFollowedSaysWhyByKind(string type, string expected) => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);

        viewer.FollowAction(new OtherAction(type));

        AssertCard(viewer, expected);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ANullActionAndAnUnlistedNamedActionAreToldAsNotFollowable() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);

        viewer.FollowAction(null);
        AssertCard(viewer, "This link cannot be followed.");

        viewer.FollowAction(new NamedAction("Print"));
        AssertCard(viewer, "This link cannot be followed.");
        return Task.CompletedTask;
    });

    private static void AssertCard(PageViewer viewer, string expected)
    {
        var card = (FrameworkElement)viewer.FindName("LinkCard");
        var title = (System.Windows.Controls.TextBlock)viewer.FindName("LinkTitle");

        Assert.Equal(expected, title.Text);
        Assert.Equal(expected, AutomationProperties.GetName(card));
        Assert.Equal(Visibility.Visible, card.Visibility);
    }

    [Fact]
    public void TheMessageSaysWhatToDo()
    {
        var problem = Problems.Restricted();

        Assert.Equal("This file cannot be changed", problem.Title);
        Assert.Contains("owner password", problem.Text);
    }
}
