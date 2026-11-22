using System.Globalization;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Measure;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the panel keeps for a tab against saves, undo and a viewer that is a step ahead.
[Collection("Application")]
public sealed class MeasurePanelStateTests
{
    private static readonly DateTimeOffset Date = new(2026, 1, 5, 9, 0, 0, TimeSpan.Zero);
    private static readonly MeasureScale One = new(1, LengthUnit.Millimetre, 100, LengthUnit.Millimetre);
    private static readonly MeasureScale Half = new(1, LengthUnit.Millimetre, 50, LengthUnit.Millimetre);

    private static DocumentTab Open(byte[] pdf) => new(PdfEditSession.Open(pdf, (string?)null), new FakeRenderer(), null, "a.pdf", null);

    // Deleting the first page leaves a gap that a compact closes, so the pages come out under other numbers.
    private static DocumentTab OpenGapped(int pages)
    {
        var tab = Open(Pdfs.Text(pages + 1));
        PageOperations.Delete(tab.Document, [0]);
        Assert.True(tab.Commit("Delete"));
        return tab;
    }

    private static (MeasurePanel Panel, FakeViewer Viewer, RecordingHost Host) Attach(DocumentTab tab)
    {
        var panel = new MeasurePanel();
        var host = new RecordingHost();
        var viewer = FakeViewer.Create(tab);
        panel.Attach(tab, viewer, host);
        return (panel, (FakeViewer)(object)viewer, host);
    }

    private static PageScales ScalesOf(MeasurePanel panel) =>
        (PageScales)typeof(MeasurePanel).GetField("_scales", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;

    private static List<Pending> WaitingOf(MeasurePanel panel) =>
        (List<Pending>)typeof(MeasurePanel).GetField("_waiting", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;

    private static Pending On(DocumentTab tab, int page) =>
        new(new MeasureItem(MeasureKind.Distance, page, [new(0, 0), new(10, 0)]), PageKey.Of(tab.Document.Pages[page]));

    private static void Compact(DocumentTab tab)
    {
        string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".pdf");
        try { tab.SaveCompact(path); }
        finally { File.Delete(path); }
    }

    private static void Mark(DocumentTab tab, int page, MeasureScale scale)
    {
        MeasureWriter.Write(tab.Document, [new MeasureItem(MeasureKind.Distance, page, [new(100, 100), new(172, 100)])], _ => scale, "Sam", Date);
        Assert.True(tab.Commit("Measure"));
    }

    [Fact]
    public Task ATypedScaleKeepsItsPageThroughASaveCompact() => Sta.Run(() =>
    {
        using var tab = OpenGapped(5);
        var (panel, _, _) = Attach(tab);
        var scales = ScalesOf(panel);
        var numbers = Enumerable.Range(0, 5).Select(p => PageScales.Key(tab.Document, p)).ToList();
        scales.Set(numbers[2], One);

        Compact(tab);

        Assert.Equal(1, tab.Rewrites);
        Assert.NotEqual(numbers, Enumerable.Range(0, 5).Select(p => PageScales.Key(tab.Document, p)));
        Assert.Equal(One, scales.For(tab.Document, 2));
        Assert.All(new[] { 0, 1, 3, 4 }, p => Assert.Equal(MeasureScale.Actual, scales.For(tab.Document, p)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task WaitingLinesFollowTheirPagesThroughCompactsDoneWhileAnotherToolWasOpen() => Sta.Run(() =>
    {
        using var tab = OpenGapped(5);
        var (panel, viewer, host) = Attach(tab);
        WaitingOf(panel).Add(On(tab, 4));
        ScalesOf(panel).Set(PageScales.Key(tab.Document, 1), One);
        panel.Detach();

        Compact(tab);
        Compact(tab);
        panel.Attach(tab, (LazyPDF.App.Viewer.IDocumentViewer)(object)viewer, host);

        var waiting = Assert.Single(WaitingOf(panel));
        Assert.Equal(4, waiting.Item.Page);
        Assert.Equal(PageScales.Key(tab.Document, 4), waiting.Key.Number);
        Assert.Empty(host.Notices);
        Assert.Equal(One, ScalesOf(panel).For(tab.Document, 1));
        Assert.Equal(MeasureScale.Actual, ScalesOf(panel).For(tab.Document, 2));
        return Task.CompletedTask;
    });

    [Fact]
    public Task LinesKeptForASignedFileSurviveACompact() => Sta.Run(() =>
    {
        using var tab = Open(StampsPanelTests.Signed(certified: false));
        var (panel, _, host) = Attach(tab);
        WaitingOf(panel).Add(On(tab, 0));
        Assert.True(panel.HandIn());

        Compact(tab);

        Assert.Single(WaitingOf(panel));
        Assert.Empty(host.Notices);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AScaleFoundOnAPageIsReadAgainWhenThePanelComesBack() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(2));
        Mark(tab, 0, Half);
        Mark(tab, 1, One);
        var (panel, viewer, host) = Attach(tab);
        Assert.Equal(One, ScalesOf(panel).For(tab.Document, 1));
        panel.Detach();

        tab.Document.Pages[1].Dictionary.Remove("Annots");
        Assert.True(tab.Commit("Delete"));
        panel.Attach(tab, (LazyPDF.App.Viewer.IDocumentViewer)(object)viewer, host);

        Assert.Equal(Half, ScalesOf(panel).For(tab.Document, 1));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheFieldsFollowTheScaleWhenAnUndoTakesItsMarksAway() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(3));
        Mark(tab, 0, Half);
        Mark(tab, 2, One);
        var (panel, viewer, _) = Attach(tab);
        viewer.PageIndex = 2;
        tab.PageIndex = 2;
        panel.Detach();
        panel.Attach(tab, (LazyPDF.App.Viewer.IDocumentViewer)(object)viewer, new RecordingHost());
        Assert.Equal(100.ToString(CultureInfo.CurrentCulture), panel.RealValue.Text);

        Assert.True(tab.Undo());

        Assert.Equal(50.ToString(CultureInfo.CurrentCulture), panel.RealValue.Text);
        Assert.Equal(Half, ScalesOf(panel).For(tab.Document, 2));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ATypedValueIsNotStoredWhenTheViewerShowsAnotherTabOrAGonePage() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(2));
        var (panel, viewer, _) = Attach(tab);

        viewer.Tab = null;
        panel.RealValue.Text = "7";
        viewer.Tab = tab;
        viewer.PageIndex = 9;
        panel.RealValue.Text = "8";

        Assert.All(new[] { 0, 1 }, p => Assert.Equal(MeasureScale.Actual, ScalesOf(panel).For(tab.Document, p)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ACalibrationInProgressEndsWhenTheDocumentChanges() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(2));
        var (panel, _, _) = Attach(tab);
        typeof(MeasurePanel).GetMethod("Tool_Calibrated", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, [0, 72d]);
        Assert.Equal(Visibility.Visible, panel.CalibrateRow.Visibility);

        Pdfs.Retitle(tab.Session, "Other");
        Assert.True(tab.Commit("Title"));

        Assert.Equal(Visibility.Collapsed, panel.CalibrateRow.Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheLengthOfTheDrawnLineIsShownAndSetAsHelpText() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(1));
        var (panel, _, _) = Attach(tab);

        typeof(MeasurePanel).GetMethod("Tool_Calibrated", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, [0, 144d]);

        string expected = Loc.T("Line drawn: {0}", new MeasureScale(1, LengthUnit.Millimetre, 1, LengthUnit.Millimetre).Length(144));
        Assert.Equal(expected, panel.CalibrateDrawn.Text);
        Assert.Equal(expected, AutomationProperties.GetHelpText(panel.CalibrateValue));
        return Task.CompletedTask;
    });

    private static void UseForAll(MeasurePanel panel) =>
        typeof(MeasurePanel).GetMethod("UseForAll_Click", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, [panel, new RoutedEventArgs()]);

    [Fact]
    public Task UseForAllAsksBeforeReplacingAScaleOnAnotherPage() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(3));
        var (panel, _, host) = Attach(tab);
        var scales = ScalesOf(panel);
        scales.Set(PageScales.Key(tab.Document, 1), Half);
        panel.RealValue.Text = "100";

        UseForAll(panel);

        Assert.Single(host.Notices);
        Assert.Equal(Half, scales.For(tab.Document, 1));
        host.Actions[0]!.Run();
        Assert.All(new[] { 0, 1, 2 }, p => Assert.Equal(One, scales.For(tab.Document, p)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task UseForAllWithNoScaleElsewhereJustApplies() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(3));
        var (panel, _, host) = Attach(tab);
        panel.RealValue.Text = "100";

        UseForAll(panel);

        Assert.Empty(host.Notices);
        Assert.Equal(One, ScalesOf(panel).For(tab.Document, 2));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheConfirmationDoesNothingOnceAnotherTabIsShown() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(3));
        using var other = Open(Pdfs.Text(3));
        var (panel, viewer, host) = Attach(tab);
        var scales = ScalesOf(panel);
        scales.Set(PageScales.Key(tab.Document, 1), Half);
        panel.RealValue.Text = "100";
        UseForAll(panel);
        panel.Detach();
        viewer.Tab = other;
        panel.Attach(other, (LazyPDF.App.Viewer.IDocumentViewer)(object)viewer, host);

        host.Actions[0]!.Run();

        Assert.Equal(Half, scales.For(tab.Document, 1));
        Assert.Equal(MeasureScale.Actual, ScalesOf(panel).For(other.Document, 1));
        return Task.CompletedTask;
    });

    private static void Call(MeasurePanel panel, string name, params object[] args) =>
        typeof(MeasurePanel).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, args);

    [Fact]
    public Task SetScaleStoresTheCalibratedScaleForThatPageOnly() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(2));
        var (panel, _, _) = Attach(tab);
        Call(panel, "Tool_Calibrated", 1, 72d);
        panel.CalibrateValue.Text = "1";

        Call(panel, "SetScale_Click", panel, new RoutedEventArgs());

        var scales = ScalesOf(panel);
        Assert.Equal(MeasureScale.From(72, 1, LengthUnit.Millimetre, LengthUnit.Millimetre), scales.For(tab.Document, 1));
        Assert.Equal(MeasureScale.Actual, scales.For(tab.Document, 0));
        Assert.Equal(Visibility.Collapsed, panel.CalibrateRow.Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task SetScaleRefusesALengthThatIsNotAboveZeroOrWouldWriteAsZero() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text(1));
        var (panel, _, _) = Attach(tab);
        Call(panel, "Tool_Calibrated", 0, 72d);

        foreach (string text in new[] { "0", "abc", "0.00001" })
        {
            panel.CalibrateValue.Text = text;
            Call(panel, "SetScale_Click", panel, new RoutedEventArgs());

            Assert.Equal(Visibility.Visible, panel.CalibrateProblem.Visibility);
            Assert.Equal(Visibility.Visible, panel.CalibrateRow.Visibility);
            Assert.Equal(MeasureScale.Actual, ScalesOf(panel).For(tab.Document, 0));
        }
        return Task.CompletedTask;
    });
}
