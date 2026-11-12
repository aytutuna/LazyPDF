using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The panel as the window drives it: the form, the list of runs, the pages' preview and the action.
[Collection("Application")]
public sealed class StampsPanelTests
{
    internal static byte[] Signed(bool certified, int pages = 2)
    {
        var document = PdfDocument.Open(Pdfs.Text(pages));
        var perms = new PdfDictionary();
        perms[certified ? "DocMDP" : "UR3"] = document.Add(new PdfDictionary());
        document.Catalog["Perms"] = perms;
        return document.SaveRewrite(new PdfSaveOptions());
    }

    private static DocumentTab Open(byte[]? bytes = null, string? password = null) =>
        new(PdfEditSession.Open(bytes ?? Pdfs.Text(3), password), new FakeRenderer(), null, "a.pdf", password);

    private static IReadOnlyList<StampInfo> Stamps(DocumentTab tab) => new PdfStamper(tab.Document).List();

    private static T Find<T>(StampsPanel panel, string name) where T : class => (T)panel.FindName(name);

    private static StampsPanel Attach(DocumentTab tab, RecordingHost host, out PageOverlay overlay)
    {
        var panel = new StampsPanel();
        var (viewer, page) = FakeViewer.Create();
        overlay = page;
        panel.Attach(tab, viewer, host);
        return panel;
    }

    private static void Select(StampsPanel panel, int index) => Find<ListBox>(panel, "RunList").SelectedIndex = index;

    private static void Edit(StampsPanel panel, string text) => Find<TextBox>(panel, "WatermarkText").Text = text;

    // The stamps write their text as hex strings.
    private static bool Shows(DocumentTab tab, int page, string text) =>
        System.Text.Encoding.Latin1.GetString(tab.Document.Pages[page].Contents()).Contains(Convert.ToHexString(System.Text.Encoding.Latin1.GetBytes(text)));

    private static DocumentTab WithWatermark()
    {
        var tab = Open();
        new PdfStamper(tab.Document).AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        tab.Commit("Add watermark");
        return tab;
    }

    [Fact]
    public Task APortraitCameraPictureIsKeptUpright() => Sta.Run(async () =>
    {
        var metadata = new BitmapMetadata("jpg");
        metadata.SetQuery("System.Photo.Orientation", (ushort)6);
        var source = BitmapSource.Create(4, 2, 96, 96, PixelFormats.Bgra32, null, new byte[32], 16);
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source, null, metadata, null));
        string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".jpg");
        using (var stream = File.Create(path)) encoder.Save(stream);
        try
        {
            using var tab = Open();
            var panel = Attach(tab, new RecordingHost(), out _);

            await panel.PickAsync(path);

            Assert.Equal(File.ReadAllBytes(path), panel.Picture);
            var image = PdfImageWriter.AddPicture(tab.Document, panel.Picture!, new WicImageCodec())!;
            Assert.Equal((2, 4), (image.Width, image.Height));
            Assert.True(Find<Button>(panel, "PictureButton").IsEnabled);
        }
        finally
        {
            File.Delete(path);
        }
    });

    [Fact]
    public Task ClosingThePanelWithARunSelectedLeavesNothingOnThePages() => Sta.Run(() =>
    {
        using var tab = WithWatermark();
        var panel = Attach(tab, new RecordingHost(), out var overlay);
        Select(panel, 0);
        Edit(panel, "OTHER");
        Assert.NotEmpty(overlay.Children);

        panel.Detach();

        Assert.Empty(overlay.Children);
        return Task.CompletedTask;
    });

    [Fact]
    public Task APickedRunIsNotPreviewedUntilTheFormChanges() => Sta.Run(() =>
    {
        using var tab = WithWatermark();
        var panel = Attach(tab, new RecordingHost(), out var overlay);

        Select(panel, 0);
        Assert.Empty(overlay.Children);
        Assert.False(panel.Action!.CanRun());

        Edit(panel, "DRAFT 2");
        Assert.NotEmpty(overlay.Children);
        Assert.True(panel.Action.CanRun());
        return Task.CompletedTask;
    });

    [Fact]
    public Task RemovingAStampAlsoTakesItsPreviewOff() => Sta.Run(async () =>
    {
        using var tab = WithWatermark();
        var host = new RecordingHost();
        var panel = Attach(tab, host, out var overlay);
        Select(panel, 0);
        Edit(panel, "DRAFT 2");

        Find<Button>(panel, "RemoveButton").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        await Sta.Until(() => host.Status == "Stamp removed.");

        Assert.Empty(overlay.Children);
        Assert.Equal("Stamp removed.", host.Status);
    });

    [Fact]
    public Task UpdatingABatesRunKeepsItsNumbers() => Sta.Run(async () =>
    {
        using var tab = Open();
        var panel = Attach(tab, new RecordingHost(), out var overlay);
        Find<ComboBox>(panel, "KindBox").SelectedIndex = (int)StampMode.Bates;
        Find<TextBox>(panel, "PrefixBox").Text = "ACME-";
        Find<TextBox>(panel, "StartBox").Text = "5";

        await panel.Action!.Run();

        Assert.Equal("8", Find<TextBox>(panel, "StartBox").Text);
        Assert.Empty(overlay.Children);
        var run = Assert.Single(Stamps(tab));

        Select(panel, 0);
        Assert.Equal("5", Find<TextBox>(panel, "StartBox").Text);
        Find<TextBox>(panel, "SuffixBox").Text = "-X";
        await panel.Action.Run();

        Assert.Equal("5", Find<TextBox>(panel, "StartBox").Text);
        Assert.Equal(run.Id, Assert.Single(Stamps(tab)).Id);
        Assert.True(Shows(tab, 0, "ACME-000005-X"));
        Assert.True(Shows(tab, 2, "ACME-000007-X"));
    });

    [Fact]
    public Task AWrittenRunComesBackIntoTheFormWhole() => Sta.Run(async () =>
    {
        using var tab = Open();
        var panel = Attach(tab, new RecordingHost(), out _);
        Edit(panel, "Line one\nLine two that is long enough to pass the label limit of the file by quite some way");
        Find<Slider>(panel, "TurnSlider").Value = 30;
        await panel.Action!.Run();

        Select(panel, 0);

        Assert.StartsWith("Line one\nLine two", Find<TextBox>(panel, "WatermarkText").Text);
        Assert.Equal(30, Find<Slider>(panel, "TurnSlider").Value);
    });

    [Fact]
    public Task ARunReadFromAFileAsksForWhatTheFileDoesNotKeep() => Sta.Run(() =>
    {
        using var tab = Open();
        new PdfStamper(tab.Document, new FakeFonts()).AddHeaderFooter(new HeaderFooterSpec { Header = new HeaderFooterBand(Left: "ACME") });
        tab.Commit("Add header and footer");
        var panel = Attach(tab, new RecordingHost(), out _);

        Select(panel, 0);
        Find<CheckBox>(panel, "ItalicBox").IsChecked = true;

        Assert.False(panel.Action!.CanRun());
        Assert.NotEqual("", Find<System.Windows.Controls.TextBlock>(panel, "ProblemText").Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFileThatForbidsChangesIsLeftAlone() => Sta.Run(async () =>
    {
        using var tab = Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Modify), "");
        var host = new RecordingHost();
        var panel = Attach(tab, host, out _);

        await panel.Action!.Run();

        Assert.Equal("This file cannot be changed", Assert.Single(host.Problems).Title);
        Assert.Empty(Stamps(tab));
        Assert.False(tab.Session.CanUndo);
    });

    [Fact]
    public Task ASignedFileAsksBeforeItIsStamped() => Sta.Run(async () =>
    {
        using var tab = Open(Signed(certified: false));
        var host = new RecordingHost();
        var panel = Attach(tab, host, out _);

        await panel.Action!.Run();
        Assert.Equal("Check before going on", Assert.Single(host.Notices));
        Assert.Empty(Stamps(tab));

        host.Actions[0]!.Run();
        await Sta.Until(() => Stamps(tab).Count == 1);
    });

    [Fact]
    public Task RemovingFromASignedFileAsksFirstToo() => Sta.Run(() =>
    {
        using var tab = Open(Signed(certified: true));
        new PdfStamper(tab.Document).AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        var host = new RecordingHost();
        var panel = Attach(tab, host, out _);

        Find<Button>(panel, "RemoveAllButton").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

        Assert.Single(host.Notices);
        Assert.Single(Stamps(tab));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ACancelledRunLeavesTheDocumentAsItWas() => Sta.Run(async () =>
    {
        using var tab = Open();
        var host = new RecordingHost { Cancelled = true };
        var panel = Attach(tab, host, out _);

        await panel.Action!.Run();

        Assert.Empty(Stamps(tab));
        Assert.False(tab.Session.CanUndo);
        Assert.Equal("Cancelled.", host.Status);
        Assert.True(panel.IsEnabled);
    });

    [Fact]
    public Task AnUndoDuringTheRunDoesNotReportAStamp() => Sta.Run(async () =>
    {
        using var tab = Open();
        Pdfs.Retitle(tab.Session, "A");
        tab.Commit("Properties");
        var host = new RecordingHost { Before = () => tab.Undo() };
        var panel = Attach(tab, host, out _);

        await panel.Action!.Run();

        Assert.Empty(Stamps(tab));
        Assert.DoesNotContain("Stamped", host.Status);
    });
}
