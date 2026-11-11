using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Comment;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Measure;

/// <summary>A measurement in the list: what it is, its value and where it lies.</summary>
public sealed record MeasureRow(MeasureItem Item, string Value, string Place, string RemoveName)
{
    public string Spoken => $"{Item.Title}, {Value}, {Place}";
}

/// <summary>The scale of each page: one typed for it, else one written on it, else the one for the file.</summary>
internal sealed class PageScales(MeasureScale start)
{
    private readonly Dictionary<int, MeasureScale> _typed = [];
    private readonly Dictionary<int, MeasureScale?> _found = [];

    public MeasureScale Default { get; private set; } = start;

    public static int Key(PdfDocument document, int page) => document.Pages[page].Reference.Number;

    // A page that is gone (the viewer can be a step ahead of the panel) takes the file's scale.
    public MeasureScale For(PdfDocument document, int page)
    {
        if (page < 0 || page >= document.Pages.Count) return Default;
        int key = Key(document, page);
        if (_typed.TryGetValue(key, out var typed)) return typed;
        if (!_found.TryGetValue(key, out var found)) _found[key] = found = MeasureScale.FindOnPage(document, document.Pages[page]);
        return found ?? Default;
    }

    public void Set(int key, MeasureScale scale) => _typed[key] = scale;

    public void SetAll(MeasureScale scale)
    {
        Default = scale;
        _typed.Clear();
    }

    // Writing marks changes what the pages hold.
    public void Forget() => _found.Clear();
}

/// <summary>
/// Distance, perimeter and area on the pages. The pointer draws on an overlay; the measurements wait in the list
/// until Add to page writes them as annotations with a /Measure scale, in one undoable step.
/// </summary>
public partial class MeasurePanel : ToolPanel
{
    private static readonly LengthUnit[] PageUnits = [LengthUnit.Millimetre, LengthUnit.Centimetre, LengthUnit.Inch];

    // Kept per tab, so that measuring in one file and looking at another loses nothing.
    private static readonly ConditionalWeakTable<DocumentTab, List<Pending>> Waiting = [];

    // What a person typed stays; a scale read from marks in the file is only the start.
    private static readonly ConditionalWeakTable<DocumentTab, PageScales> Scales = [];

    private List<Pending> _waiting = [];
    private MeasureTool? _tool;
    private MeasureOverlay? _overlay;
    private PageScales _scales = new(MeasureScale.Actual);
    private bool _ready;
    private bool _paused;
    private double _calibrated;
    private int _calibratedKey;

    public MeasurePanel()
    {
        InitializeComponent();
        Action = new ToolAction(Loc.T("Add to page"), "", () => _waiting.Count > 0, AddAsync);
        Summary.Text = ToolCatalog.Find("measure")?.Summary;
        Fill(PageUnit, PageUnits, LengthUnit.Millimetre);
        Fill(RealUnit, Enum.GetValues<LengthUnit>(), LengthUnit.Millimetre);
        Fill(CalibrateUnit, Enum.GetValues<LengthUnit>(), LengthUnit.Millimetre);
        _ready = true;
        ShowReadout();
    }

    public override ToolAction? Action { get; }

    protected override void OnAttach()
    {
        _waiting = Waiting.GetOrCreateValue(Tab!);
        _paused = false;
        if (!Scales.TryGetValue(Tab!, out var kept))
        {
            kept = new PageScales(MeasureScale.Find(Tab!.Document) ?? MeasureScale.Actual);
            Scales.Add(Tab!, kept);
        }
        _scales = kept;
        ShowScale(ScaleOf(Viewer!.PageIndex));
        if (PerimeterMode.IsChecked != true && AreaMode.IsChecked != true) DistanceMode.IsChecked = true;
        _tool = new MeasureTool(Viewer!) { Kind = Kind(), Snap = SnapToggle.IsChecked == true };
        _overlay = new MeasureOverlay(Viewer!, _tool);
        _tool.Changed += Tool_Changed;
        _tool.Finished += Tool_Finished;
        _tool.Calibrated += Tool_Calibrated;
        Viewer!.PointerTool = _tool;
        Viewer.ViewChanged += Viewer_ViewChanged;
        Viewer.PageChanged += Viewer_PageChanged;
        Viewer.ModeChanged += Viewer_ModeChanged;
        Viewer.View.PreviewKeyDown += View_PreviewKeyDown;
        Tab!.Changed += Tab_Changed;
        DropStale();
        Rebuild();
    }

    protected override void OnDetach()
    {
        Viewer!.ViewChanged -= Viewer_ViewChanged;
        Viewer.PageChanged -= Viewer_PageChanged;
        Viewer.ModeChanged -= Viewer_ModeChanged;
        Viewer.View.PreviewKeyDown -= View_PreviewKeyDown;
        Tab!.Changed -= Tab_Changed;
        _tool!.Changed -= Tool_Changed;
        _tool.Finished -= Tool_Finished;
        _tool.Calibrated -= Tool_Calibrated;
        EndCalibrate();
        if (ReferenceEquals(Viewer.PointerTool, _tool)) Viewer.PointerTool = null;
        _overlay!.Clear();
        _tool = null;
        _overlay = null;
    }

    private MeasureScale ScaleOf(int page) => _scales.For(Tab!.Document, page);

    private List<MeasureItem> Items => [.. _waiting.Select(p => p.Item)];

    private MeasureKind Kind() => PerimeterMode.IsChecked == true ? MeasureKind.Perimeter : AreaMode.IsChecked == true ? MeasureKind.Area : MeasureKind.Distance;

    private static void Fill(ComboBox box, LengthUnit[] units, LengthUnit selected)
    {
        foreach (var unit in units) box.Items.Add(new ComboBoxItem { Content = unit.Symbol(), Tag = unit });
        box.SelectedIndex = Array.IndexOf(units, selected);
    }

    private void Kind_Checked(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _paused = false;
        EndCalibrate();
        if (_tool is not null)
        {
            _tool.Cancel();
            _tool.Kind = Kind();
            if (!ReferenceEquals(Viewer!.PointerTool, _tool)) Viewer.PointerTool = _tool;
        }
        ShowReadout();
    }

    private void Snap_Click(object sender, RoutedEventArgs e)
    {
        if (_tool is not null) _tool.Snap = SnapToggle.IsChecked == true;
    }

    private void Scale_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        bool good = double.TryParse(PageValue.Text, CultureInfo.CurrentCulture, out double page)
            & double.TryParse(RealValue.Text, CultureInfo.CurrentCulture, out double real);
        var scale = new MeasureScale(page, UnitOf(PageUnit), real, UnitOf(RealUnit));
        good &= scale.IsValid;
        ScaleProblem.Visibility = good ? Visibility.Collapsed : Visibility.Visible;
        if (!good) return;
        _scales.Set(PageScales.Key(Tab!.Document, Viewer!.PageIndex), scale);
        Rebuild();
    }

    private void UseForAll_Click(object sender, RoutedEventArgs e)
    {
        if (!double.TryParse(PageValue.Text, CultureInfo.CurrentCulture, out double page)
            || !double.TryParse(RealValue.Text, CultureInfo.CurrentCulture, out double real)) return;
        var scale = new MeasureScale(page, UnitOf(PageUnit), real, UnitOf(RealUnit));
        if (!scale.IsValid) return;
        _scales.SetAll(scale);
        ShowScale(ScaleOf(Viewer!.PageIndex));
        Rebuild();
    }

    // While tabs switch the viewer already shows the next file; the attach that follows shows its scale.
    private void Viewer_PageChanged(object? sender, EventArgs e)
    {
        if (ReferenceEquals(Viewer!.Tab, Tab)) ShowScale(ScaleOf(Viewer.PageIndex));
    }

    private void ShowScale(MeasureScale scale)
    {
        _ready = false;
        PageValue.Text = scale.Page.ToString(CultureInfo.CurrentCulture);
        RealValue.Text = scale.Real.ToString(CultureInfo.CurrentCulture);
        SelectUnit(PageUnit, scale.PageUnit);
        SelectUnit(RealUnit, scale.RealUnit);
        _ready = true;
        ScaleHeading.Text = Loc.T("Scale for page {0}", Viewer!.PageLabel(Viewer.PageIndex));
        ScaleProblem.Visibility = Visibility.Collapsed;
    }

    private static void SelectUnit(ComboBox box, LengthUnit unit) =>
        box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (LengthUnit)i.Tag == unit) ?? box.SelectedItem;

    private static LengthUnit UnitOf(ComboBox box) => (LengthUnit)((ComboBoxItem)box.SelectedItem).Tag;

    private void Tool_Changed(object? sender, EventArgs e)
    {
        _overlay?.Draw(Items, ScaleOf);
        ShowReadout();
    }

    private void Tool_Finished(MeasureItem item)
    {
        _waiting.Add(new Pending(item, PageKey.Of(Tab!.Document.Pages[item.Page])));
        Rebuild();
    }

    private void Tool_Calibrated(int page, double points)
    {
        _calibrated = points;
        _calibratedKey = PageScales.Key(Tab!.Document, page);
        CalibrateProblem.Visibility = Visibility.Collapsed;
        SelectUnit(CalibrateUnit, UnitOf(RealUnit));
        CalibrateRow.Visibility = Visibility.Visible;
        CalibrateValue.Focus();
        CalibrateValue.SelectAll();
    }

    // Two points of a page and the length a person says they stand for make the scale.
    internal static MeasureScale ScaleFrom(double points, double length, LengthUnit pageUnit, LengthUnit realUnit) =>
        new(points * LengthUnits.PointInMetres / pageUnit.Metres(), pageUnit, length, realUnit);

    private void Calibrate_Click(object sender, RoutedEventArgs e)
    {
        if (_tool is null) return;
        _paused = false;
        if (DistanceMode.IsChecked != true) DistanceMode.IsChecked = true;
        EndCalibrate();
        _tool.Cancel();
        _tool.Calibrate = true;
        if (!ReferenceEquals(Viewer!.PointerTool, _tool)) Viewer.PointerTool = _tool;
        ShowReadout();
    }

    private void EndCalibrate()
    {
        if (_tool is not null) _tool.Calibrate = false;
        _calibrated = 0;
        CalibrateRow.Visibility = Visibility.Collapsed;
        ShowReadout();
    }

    private void SetScale_Click(object sender, RoutedEventArgs e)
    {
        if (!double.TryParse(CalibrateValue.Text, CultureInfo.CurrentCulture, out double length) || !(length > 0))
        {
            CalibrateProblem.Visibility = Visibility.Visible;
            return;
        }
        var scale = ScaleFrom(_calibrated, length, UnitOf(PageUnit), UnitOf(CalibrateUnit));
        if (!scale.IsValid)
        {
            CalibrateProblem.Visibility = Visibility.Visible;
            return;
        }
        _scales.Set(_calibratedKey, scale);
        ShowScale(ScaleOf(Viewer!.PageIndex));
        EndCalibrate();
        Rebuild();
    }

    private void CancelCalibrate_Click(object sender, RoutedEventArgs e) => EndCalibrate();

    private void CalibrateValue_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) SetScale_Click(sender, e);
        else if (e.Key == Key.Escape) EndCalibrate();
        else return;
        e.Handled = true;
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e) => _overlay?.Draw(Items, ScaleOf);

    // The viewer's own Hand and Select buttons took the pointer: none of the kinds is armed until one is picked again.
    private void Viewer_ModeChanged(object? sender, EventArgs e)
    {
        _tool?.Cancel();
        EndCalibrate();
        _paused = true;
        foreach (var button in new[] { DistanceMode, PerimeterMode, AreaMode }) button.IsChecked = false;
        ShowReadout();
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_tool is null || _tool.Points.Count == 0 || Keyboard.FocusedElement is TextBox or ComboBox or PasswordBox) return;
        if (e.Key == Key.Escape) _tool.Cancel();
        else if (e.Key == Key.Back) _tool.Undo();
        else return;
        e.Handled = true;
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        _tool?.Forget();
        _scales.Forget();
        DropStale();
        Rebuild();
    }

    // Measurements wait with display points of a page as it was; a page that was turned, cut or removed no longer takes them.
    private void DropStale()
    {
        var kept = Pending.Keep(_waiting, Tab!.Document);
        int dropped = _waiting.Count - kept.Count;
        _waiting.Clear();
        _waiting.AddRange(kept);
        if (dropped > 0) Host?.ShowNotice(Loc.T("Measurements dropped"), Loc.T("The pages they were on changed. Measure them again."));
    }

    private void Finish_Click(object sender, RoutedEventArgs e) => _tool?.Finish();

    private void StartOver_Click(object sender, RoutedEventArgs e) => _tool?.Cancel();

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not MeasureRow row) return;
        _waiting.RemoveAll(p => ReferenceEquals(p.Item, row.Item));
        Rebuild();
    }

    // Reads the list again after it or the scale changed.
    private void Rebuild()
    {
        Results.ItemsSource = Items.Select(i => new MeasureRow(i, i.Value(ScaleOf(i.Page)), Loc.T("Page {0}", Viewer?.PageLabel(i.Page) ?? (i.Page + 1).ToString()),
                                                                Loc.T("Remove {0}", i.Title))).ToList();
        Empty.Visibility = _waiting.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Tab!.PendingMeasurements = _waiting.Count;
        _overlay?.Draw(Items, ScaleOf);
        RaiseActionChanged();
        ShowReadout();
    }

    private Task AddAsync()
    {
        var tab = Tab!;
        if (!Exchange.CanComment(tab.Document))
        {
            Host!.ShowProblem(new Problem(Loc.T("Not allowed"), Loc.T("This file does not let anyone add marks. Ask its owner for a copy that does.")));
            return Task.CompletedTask;
        }
        if (!MarkWork.Cautioned(tab, Host!, () =>
            {
                if (ReferenceEquals(Tab, tab)) Add(tab);
            })) Add(tab);
        return Task.CompletedTask;
    }

    private void Add(DocumentTab tab)
    {
        int count;
        try
        {
            count = MeasureWriter.Write(tab.Document, Items, item => ScaleOf(item.Page), Environment.UserName, DateTimeOffset.Now, new SystemFontSource());
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or PdfPermissionException)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Measurements not added"), Loc.T("They could not be written to the file. Nothing was changed.")));
            Rebuild();
            return;
        }
        // Whatever was written is one step, so Undo takes all of it back.
        if (!MarkWork.Commit(tab, Host!, Loc.T("Measure"))) return;
        _waiting.Clear();
        Rebuild();
        Host!.SetStatus(Loc.Plural(count, "Added {0} measurement", "Added {0} measurements"));
    }

    private void ShowReadout()
    {
        var tool = _tool;
        FinishButton.IsEnabled = tool?.CanFinish == true;
        StartOverButton.IsEnabled = tool?.Points.Count > 0;
        Hint.Text = tool?.Calibrate == true ? Loc.T("Click the two ends of something whose real length you know.")
            : _paused ? Loc.T("Pick Distance, Perimeter or Area to measure again.")
            : Kind() == MeasureKind.Distance
            ? Loc.T("Click the two ends. Hold Shift for straight lines.")
            : Loc.T("Click each corner, then double-click to finish. Hold Shift for straight lines.");
        if (tool is null || tool.Points.Count == 0)
        {
            Readout.Text = "—";
            AngleReadout.Text = "—";
            return;
        }
        var points = tool.Points.ToList();
        if (tool.Hover is { } hover && tool.HoverPage == tool.Page) points.Add(hover);
        Readout.Text = points.Count < 2 ? "—" : new MeasureItem(tool.Kind, tool.Page, points).Value(ScaleOf(tool.Page));
        AngleReadout.Text = MeasureShape.Angle(points, tool.Kind) is { } angle
            ? Loc.T("{0}°", Math.Round(angle, 1).ToString("0.0", CultureInfo.CurrentCulture)) : "—";
    }
}
