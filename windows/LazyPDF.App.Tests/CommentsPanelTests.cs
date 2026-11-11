using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LazyPDF.App.Panels.Comments;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tests.Tools.Comment;
using LazyPDF.App.Documents;
using LazyPDF.App.Tests.Tools.Edit;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class CommentsPanelTests
{
    private static readonly MarkStyle Red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1] };

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public Task PickedCommentShowsItsWholeText(bool hasText) => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        string text = hasText ? string.Join(" ", Enumerable.Repeat("a long remark that the list row cuts short", 30)) : "";
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, text);
        f.Tab.Commit("Mark");
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, new RecordingHost());

        ((ListBox)panel.FindName("Comments")).SelectedIndex = 0;

        var full = (TextBox)panel.FindName("FullText");
        Assert.Equal(text, full.Text);
        Assert.Equal(hasText ? Visibility.Visible : Visibility.Collapsed, full.Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task MarkedCanBeFilteredButNotSet() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        f.Tab.Commit("Mark");
        var parent = PdfComments.List(f.Document)[0].Annotation;
        PdfComments.SetStatus(f.Document, parent, ReviewStatus.Marked, "Ana", DateTimeOffset.Now);
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, new RecordingHost());

        ((ListBox)panel.FindName("Comments")).SelectedIndex = 0;

        Assert.Equal(5, ((ComboBox)panel.FindName("StatusBox")).Items.Count);
        Assert.Equal(8, ((ComboBox)panel.FindName("StatusFilter")).Items.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ANewReplyIsScrolledIntoView() => Sta.Run(async () =>
    {
        using var f = new CommentFixture();
        string text = string.Join(" ", Enumerable.Repeat("a long remark that the list row cuts short", 30));
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, text);
        f.Tab.Commit("Mark");
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, new RecordingHost());
        var window = new Window { Content = panel, Width = 300, Height = 700 };
        window.Show();
        ((ListBox)panel.FindName("Comments")).SelectedIndex = 0;
        var scroll = (ScrollViewer)panel.FindName("TextScroll");
        scroll.UpdateLayout();

        ((TextBox)panel.FindName("ReplyBox")).Text = "agreed";
        var button = (Button)panel.FindName("ReplyButton");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Dispatcher.Yield(DispatcherPriority.Loaded);

        Assert.True(scroll.ScrollableHeight > 0);
        Assert.Equal(scroll.ScrollableHeight, scroll.VerticalOffset);
        window.Close();
    });

    [Fact]
    public Task ARestrictedFileShowsTheTextButCannotBeAnswered() => Sta.Run(() =>
    {
        const string note = "/Annots [<< /Type /Annot /Subtype /Text /Rect [50 700 70 720] /T (Ana) /Contents (check this) >>]";
        var locked = PdfDocument.Open(EditPdf.Make("", note));
        var security = PdfSecurity.Create("", "owner", PdfPermissions.Print, PdfCryptStrength.Aes256, locked.FirstId ?? []);
        using var tab = new DocumentTab(PdfEditSession.Open(locked.SaveRewrite(new PdfSaveOptions(Security: security)), ""), new FakeRenderer(), null, "locked.pdf");
        var panel = new CommentsSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());

        ((ListBox)panel.FindName("Comments")).SelectedIndex = 0;

        Assert.Equal(Visibility.Visible, ((FrameworkElement)panel.FindName("Detail")).Visibility);
        Assert.Equal("check this", ((TextBox)panel.FindName("FullText")).Text);
        Assert.False(((UIElement)panel.FindName("Answering")).IsEnabled);
        return Task.CompletedTask;
    });
}
