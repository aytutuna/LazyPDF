using LazyPDF.App.Documents;
using LazyPDF.App.Services;
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
    private static void Restore(string? text)
    {
        if (text is null) Clipboard.Clear();
        else Clipboard.SetText(text);
    }

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
        string? kept = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        Clipboard.SetText("before");

        try
        {
            await viewer.CopySelectionAsync();
            viewer.ShowFind();

            Assert.Equal("before", Clipboard.GetText());
        }
        finally
        {
            Restore(kept);
        }
        AssertCard(viewer, "The owner of this file does not allow copying.");
        Assert.Equal("", ((FindBar)viewer.FindName("Find")).Query.Text);
    });

    [Fact]
    public Task CopyingAnAreaIsRefusedAndTheClipboardStaysAsItWas() => Sta.Run(async () =>
    {
        var viewer = new PageViewer(null);
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy)), new WindowsPageRenderer(), null, "a.pdf");
        viewer.Show(tab);
        string? kept = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        Clipboard.SetText("before");

        try
        {
            await viewer.CopyAreaAsync(0, new Rect(10, 10, 100, 100));

            Assert.Equal("before", Clipboard.GetText());
        }
        finally
        {
            Restore(kept);
        }
        AssertCard(viewer, "The owner of this file does not allow copying.");
    });

    [Fact]
    public Task AnAreaIsDrawnAtTheSizeAskedFor() => Sta.Run(async () =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new WindowsPageRenderer(), null, "a.pdf");
        var surface = new PageSurface();
        surface.Show(tab);

        var image = await surface.RenderAreaAsync(0, new Rect(10, 20, 72, 36), 192);

        Assert.NotNull(image);
        Assert.InRange(image.Width, 191, 193);
        Assert.InRange(image.Height, 95, 97);
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

    [Fact]
    public Task AllowingASiteSkipsTheCardOnlyForThatHttpsSite() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var viewer = new PageViewer(dir.Path);
        var opened = new List<string>();
        viewer.OpenAddress = opened.Add;
        var card = (FrameworkElement)viewer.FindName("LinkCard");
        var remember = (System.Windows.Controls.CheckBox)viewer.FindName("LinkRemember");

        viewer.AskToOpen("https://Example.org/a");
        Assert.Equal(Visibility.Visible, card.Visibility);
        Assert.Equal(Visibility.Visible, remember.Visibility);
        remember.IsChecked = true;
        ((System.Windows.Controls.Button)viewer.FindName("LinkOpen")).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.Equal(["https://Example.org/a"], opened);
        Assert.Equal(["https://example.org"], AppPreferencesStore.Load(dir.Path).AllowedLinkHosts);

        opened.Clear();
        viewer.AskToOpen("https://example.org/b");
        Assert.Equal(["https://example.org/b"], opened);
        Assert.Equal(Visibility.Collapsed, card.Visibility);

        viewer.AskToOpen("http://example.org/");
        Assert.Equal(Visibility.Visible, card.Visibility);
        Assert.Equal(Visibility.Collapsed, remember.Visibility);
        viewer.AskToOpen("https://other.example/");
        Assert.Equal(Visibility.Visible, card.Visibility);
        Assert.False(remember.IsChecked);
        Assert.Single(opened);

        var item = (System.Windows.Controls.MenuItem)viewer.FindName("ForgetLinksItem");
        item.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.MenuItem.ClickEvent));
        Assert.Empty(AppPreferencesStore.Load(dir.Path).AllowedLinkHosts);
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
