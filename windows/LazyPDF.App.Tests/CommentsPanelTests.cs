using System.Globalization;
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
    public Task ByDateListsTheNewestFirstUnderItsDay() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var older = new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero);
        var newer = new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero);
        new Marker(f.Document, new FakeFonts(), "Ana", older).Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "old");
        new Marker(f.Document, new FakeFonts(), "Ana", newer).Add(MarkTool.Note, 0, [new Point(60, 200)], Red, "new");
        f.Tab.Commit("Mark");
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, new RecordingHost());

        ((ComboBox)panel.FindName("GroupBy")).SelectedIndex = 1;

        var rows = ((ListBox)panel.FindName("Comments")).Items.Cast<CommentRow>().ToList();
        Assert.Equal("new", rows[0].Text);
        Assert.Equal(newer.ToLocalTime().Date.ToString("d", CultureInfo.CurrentCulture), rows[0].Group);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ByDateKeepsNoDateLastAndPageOrderWithinOneMoment() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var at = new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero);
        var marker = new Marker(f.Document, new FakeFonts(), "Ana", at);
        marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "upper");
        marker.Add(MarkTool.Note, 0, [new Point(60, 300)], Red, "lower");
        marker.Add(MarkTool.Note, 0, [new Point(60, 200)], Red, "undated");
        f.Tab.Commit("Mark");
        var undated = PdfAnnotations.ReadAll(f.Document).Single(a => a.Contents == "undated");
        undated.Dictionary["M"] = null;
        undated.Dictionary["CreationDate"] = null;

        var list = PdfComments.List(f.Document, null, CommentOrder.Date);

        Assert.Equal(["upper", "lower", "undated"], CommentsSidePanel.NewestFirst(list).Select(c => c.Text));
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

    private static CommentsSidePanel Open(CommentFixture f, RecordingHost host)
    {
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, host);
        ((ListBox)panel.FindName("Comments")).SelectedIndex = 0;
        return panel;
    }

    private static void Click(CommentsSidePanel panel, string name) => ((Button)panel.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    [Fact]
    public Task DeletingACommentTakesItOutAndUndoBringsItBack() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        f.Tab.Commit("Mark");
        var host = new RecordingHost();
        var panel = Open(f, host);

        Click(panel, "DeleteButton");

        Assert.Empty(PdfComments.List(f.Document));
        Assert.Equal("Comment deleted.", host.Status);
        Assert.True(f.Tab.Undo());
        Assert.Single(PdfComments.List(f.Document));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ImportingAnXfdfAddsTheCommentsAsOneUndoStep() => Sta.Run(async () =>
    {
        using var source = new CommentFixture();
        source.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        source.Tab.Commit("Mark");
        var exported = Exchange.Export(source.Document, "a.pdf", xfdf: true);
        using var f = new CommentFixture();
        var host = new RecordingHost();
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, host);

        await panel.ImportAsync(f.Tab, host, exported.Data, "a.xfdf", xfdf: true);

        Assert.Equal("check", Assert.Single(PdfComments.List(f.Document)).Annotation.Contents);
        Assert.Equal("Imported 1 comment.", host.Status);
        Assert.True(f.Tab.Undo());
        Assert.Empty(PdfComments.List(f.Document));
    });

    [Fact]
    public Task TheListIsLeftAloneWhileAnImportRuns() => Sta.Run(async () =>
    {
        using var source = new CommentFixture();
        source.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        source.Tab.Commit("Mark");
        var exported = Exchange.Export(source.Document, "a.pdf", xfdf: true);
        using var f = new CommentFixture();
        var host = new RecordingHost();
        var panel = new CommentsSidePanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, host);
        var groupBy = (ComboBox)panel.FindName("GroupBy");
        host.Before = () =>
        {
            Assert.False(groupBy.IsEnabled);
            Assert.False(((Button)panel.FindName("MoreButton")).IsEnabled);
            panel.Detach();
            panel.Attach(f.Tab, FakeViewer.Create().Viewer, host);
            groupBy.SelectedIndex = 1;
            Assert.Null(((ListBox)panel.FindName("Comments")).ItemsSource);
        };

        await panel.ImportAsync(f.Tab, host, exported.Data, "a.xfdf", xfdf: true);

        Assert.True(groupBy.IsEnabled);
        Assert.True(((Button)panel.FindName("MoreButton")).IsEnabled);
        Assert.Equal(1, ((ListBox)panel.FindName("Comments")).Items.Count);
    });

    [Fact]
    public Task EditingTheTextIsOneUndoStep() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        f.Tab.Commit("Mark");
        var host = new RecordingHost();
        var panel = Open(f, host);

        Click(panel, "EditButton");
        var full = (TextBox)panel.FindName("FullText");
        Assert.False(full.IsReadOnly);
        full.Text = "checked";
        Click(panel, "SaveEditButton");

        Assert.Equal("checked", PdfComments.List(f.Document)[0].Text);
        Assert.True(full.IsReadOnly);
        Assert.True(f.Tab.Undo());
        Assert.Equal("check", PdfComments.List(f.Document)[0].Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EditingANoteDropsItsRichText() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        f.Tab.Commit("Mark");
        PdfComments.List(f.Document)[0].Annotation.Dictionary["RC"] = PdfText.ToObject("<body><p>check</p></body>");
        f.Tab.Commit("Rich text");
        var panel = Open(f, new RecordingHost());

        Click(panel, "EditButton");
        ((TextBox)panel.FindName("FullText")).Text = "checked";
        Click(panel, "SaveEditButton");

        var annotation = PdfComments.List(f.Document)[0].Annotation;
        Assert.Equal("checked", PdfComments.List(f.Document)[0].Text);
        Assert.Null(annotation.Dictionary["RC"]);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TextNoFontCanDrawIsAProblemAndKeepsTheBoxEditable() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], Red, "check");
        f.Tab.Commit("Mark");
        var host = new RecordingHost();
        var panel = Open(f, host);
        panel.Fonts = new FakeFonts();

        Click(panel, "EditButton");
        var full = (TextBox)panel.FindName("FullText");
        full.Text = "Çalışma ğ";
        Click(panel, "SaveEditButton");

        Assert.Equal(AnnotationText.NoFont, host.Problems.Single().Text);
        Assert.False(full.IsReadOnly);
        Assert.Equal("check", PdfComments.List(f.Document)[0].Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ASignedFileAsksBeforeTheCommentIsDeleted() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Note, 0, [new Point(60, 80)], Red, "check");
        f.Tab.Commit("Mark");
        using var ada = PdfDigitalId.Create("Ada", null, DateTimeOffset.Now.AddDays(-1), years: 1, keyBits: 2048);
        PdfSigner.Sign(f.Tab.Session, new PdfSignRequest(ada, DateTimeOffset.Now) { Fonts = new FakeFonts() });
        var host = new RecordingHost();
        var panel = Open(f, host);

        Click(panel, "DeleteButton");

        Assert.Single(host.Notices);
        Assert.Single(PdfComments.List(f.Document));
        return Task.CompletedTask;
    });
}
