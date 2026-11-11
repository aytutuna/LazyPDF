using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class FillSignPanelTests
{
    [Fact]
    public Task ARemovedSignatureIsKeptUntilTheNoticeIsAnswered() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var saved = new SavedSignatures(dir.Sub("sigs"));
        var item = saved.Add(SavedKind.Signature, new PdfRgbaImage(2, 1, [1, 0, 0, 255, 0, 1, 0, 128]));
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new FillSignPanel(dir.Sub("sigs"));
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, host);
        var list = (ListBox)panel.FindName("SavedList");
        var row = (SavedRow)list.Items[0]!;

        var remove = typeof(FillSignPanel).GetMethod("Remove_Click", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
        remove.Invoke(panel, [new Button { DataContext = row }, new RoutedEventArgs()]);

        Assert.True(File.Exists(item.Path));
        Assert.Equal("Delete this signature?", host.Notices[0]);
        Assert.Equal("Delete", host.Actions[0]!.Text);

        host.Actions[0]!.Run();

        Assert.False(File.Exists(item.Path));
        return Task.CompletedTask;
    });

    [Fact]
    public Task KeepPlacingStaysArmedAfterEachPlacementUntilItIsUnticked() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var panel = new FillSignPanel(dir.Sub("sigs"));
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, new RecordingHost());
        ((RadioButton)panel.FindName("TextKind")).IsChecked = true;
        ((TextBox)panel.FindName("WordsBox")).Text = "AB";
        var keep = (CheckBox)panel.FindName("KeepPlacing");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var begin = typeof(FillSignPanel).GetMethod("Begin", flags)!;
        var placed = typeof(FillSignPanel).GetMethod("Placed", flags)!;

        keep.IsChecked = true;
        begin.Invoke(panel, []);
        placed.Invoke(panel, [0, new Point(50, 50), null]);

        Assert.Equal("Stop placing", panel.Action!.Text);
        Assert.Equal("Place text", tab.Session.UndoLabel);

        keep.IsChecked = false;
        placed.Invoke(panel, [0, new Point(50, 100), null]);

        Assert.Equal("Place on page", panel.Action!.Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AKeptSignatureIsSavedAndAOneOffIsNot() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var panel = new CertificatesPanel(dir.Sub("sigs"));
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, new RecordingHost());
        var maker = (SignatureMaker)panel.FindName("Maker");
        var list = (ListBox)panel.FindName("SavedList");
        var saved = new SavedSignatures(dir.Sub("sigs"));
        var made = typeof(CertificatesPanel).GetMethod("Maker_Made", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
        ((TextBox)maker.FindName("NameBox")).Text = "Ann";
        var keep = (CheckBox)maker.FindName("KeepBox");

        keep.IsChecked = false;
        made.Invoke(panel, [maker, EventArgs.Empty]);

        Assert.Empty(saved.List(SavedKind.Signature));
        Assert.Single(list.Items);

        keep.IsChecked = true;
        made.Invoke(panel, [maker, EventArgs.Empty]);

        Assert.Single(saved.List(SavedKind.Signature));
        Assert.Single(list.Items);
        Assert.IsType<SavedRow>(list.SelectedItem);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ACommitThatWillNotReadBackIsAProblemAndLeavesNothingBehind() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var renderer = new FailingRenderer();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), renderer, null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new FillSignPanel(dir.Sub("sigs"));
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, host);
        ((RadioButton)panel.FindName("TextKind")).IsChecked = true;
        ((TextBox)panel.FindName("WordsBox")).Text = "AB";
        ((CheckBox)panel.FindName("KeepPlacing")).IsChecked = true;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(FillSignPanel).GetMethod("Begin", flags)!.Invoke(panel, []);
        renderer.Fails = true;

        typeof(FillSignPanel).GetMethod("Placed", flags)!.Invoke(panel, [0, new Point(50, 50), null]);

        Assert.Equal("Change not kept", host.Problems.Single().Title);
        Assert.False(tab.Document.HasChanges);
        Assert.Equal("Place on page", panel.Action!.Text);
        return Task.CompletedTask;
    });

    private sealed class FailingRenderer : IDocumentRenderer
    {
        public bool Fails { get; set; }

        public bool Load(PdfEditSession session, string? password) =>
            Fails ? throw PdfReadException.Damaged("The update does not read back.") : true;

        public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

        public PdfRgbaImage? Render(int pageIndex, double dpi) => null;

        public void Dispose() { }
    }
}
