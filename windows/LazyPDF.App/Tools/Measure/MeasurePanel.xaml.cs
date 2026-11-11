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

/// <summary>
/// Distance, perimeter and area on the pages. The pointer draws on an overlay; the measurements wait in the list
/// until Add to page writes them as annotations with a /Measure scale, in one undoable step.
/// </summary>
public partial class MeasurePanel : ToolPanel
{
    private static readonly LengthUnit[] PageUnits = [LengthUnit.Millimetre, LengthUnit.Centimetre, LengthUnit.Inch];

    // Kept per tab, so that measuring in one file and looking at another loses nothing.
    private static readonly ConditionalWeakTable<DocumentTab, List<Pending>> Waiting = [];

    // The scale a person typed for a file; one read from marks in the file is only the start.
    private static readonly ConditionalWeakTable<DocumentTab, MeasureScale> Scales = [];

    private List<Pending> _waiting = [];
    private MeasureTool? _tool;
    private MeasureOverlay? _overlay;
    private MeasureScale _scale = MeasureScale.Actual;
    private bool _ready;
    private bool _paused;

    public MeasurePanel()
    {
        InitializeComponent();
        Action = new ToolAction(Loc.T("Add to page"), "", () => _waiting.Count > 0, AddAsync);
        Summary.Text = ToolCatalog.Find("measure")?.Summary;
        Fill(PageUnit, PageUnits, LengthUnit.Millimetre);
        Fill(RealUnit, Enum.GetValues<LengthUnit>(), LengthUnit.Millimetre);
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
            kept = MeasureScale.Find(Tab!.Document) ?? MeasureScale.Actual;
            Scales.Add(Tab!, kept);
        }
        ShowScale(kept);
        if (PerimeterMode.IsChecked != true && AreaMode.IsChecked != true) DistanceMode.IsChecked = true;
        _tool = new MeasureTool(Viewer!) { Kind = Kind(), Snap = SnapToggle.IsChecked == true };
        _overlay = new MeasureOverlay(Viewer!, _tool);
        _tool.Changed += Tool_Changed;
        _tool.Finished += Tool_Finished;
        Viewer!.PointerTool = _tool;
        Viewer.ViewChanged += Viewer_ViewChanged;
        Viewer.ModeChanged += Viewer_ModeChanged;
        Viewer.View.PreviewKeyDown += View_PreviewKeyDown;
        Tab!.Changed += Tab_Changed;
        DropStale();
        Rebuild();
    }

    protected override void OnDetach()
    {
        Viewer!.ViewChanged -= Viewer_ViewChanged;
        Viewer.ModeChanged -= Viewer_ModeChanged;
        Viewer.View.PreviewKeyDown -= View_PreviewKeyDown;
        Tab!.Changed -= Tab_Changed;
        _tool!.Changed -= Tool_Changed;
        _tool.Finished -= Tool_Finished;
        if (ReferenceEquals(Viewer.PointerTool, _tool)) Viewer.PointerTool = null;
        _overlay!.Clear();
        _tool = null;
        _overlay = null;
    }

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
        _scale = scale;
        Scales.AddOrUpdate(Tab!, scale);
        Rebuild();
    }

    private void ShowScale(MeasureScale scale)
    {
        _ready = false;
        PageValue.Text = scale.Page.ToString(CultureInfo.CurrentCulture);
        RealValue.Text = scale.Real.ToString(CultureInfo.CurrentCulture);
        SelectUnit(PageUnit, scale.PageUnit);
        SelectUnit(RealUnit, scale.RealUnit);
        _scale = scale;
        _ready = true;
        ScaleProblem.Visibility = Visibility.Collapsed;
    }

    private static void SelectUnit(ComboBox box, LengthUnit unit) =>
        box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (LengthUnit)i.Tag == unit) ?? box.SelectedItem;

    private static LengthUnit UnitOf(ComboBox box) => (LengthUnit)((ComboBoxItem)box.SelectedItem).Tag;

    private void Tool_Changed(object? sender, EventArgs e)
    {
        _overlay?.Draw(Items, _scale);
        ShowReadout();
    }

    private void Tool_Finished(MeasureItem item)
    {
        _waiting.Add(new Pending(item, PageKey.Of(Tab!.Document.Pages[item.Page])));
        Rebuild();
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e) => _overlay?.Draw(Items, _scale);

    // The viewer's own Hand and Select buttons took the pointer: none of the kinds is armed until one is picked again.
    private void Viewer_ModeChanged(object? sender, EventArgs e)
    {
        _tool?.Cancel();
        _paused = true;
        foreach (var button in new[] { DistanceMode, PerimeterMode, AreaMode }) button.IsChecked = false;
        ShowReadout();
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_tool is null || _tool.Points.Count == 0) return;
        if (e.Key == Key.Escape) _tool.Cancel();
        else if (e.Key == Key.Back) _tool.Undo();
        else return;
        e.Handled = true;
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        _tool?.Forget();
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
        Results.ItemsSource = Items.Select(i => new MeasureRow(i, i.Value(_scale), Loc.T("Page {0}", Viewer?.PageLabel(i.Page) ?? (i.Page + 1).ToString()),
                                                                Loc.T("Remove {0}", i.Title))).ToList();
        Empty.Visibility = _waiting.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _overlay?.Draw(Items, _scale);
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
            count = MeasureWriter.Write(tab.Document, Items, _scale, Environment.UserName, DateTimeOffset.Now, new SystemFontSource());
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
        Hint.Text = _paused ? Loc.T("Pick Distance, Perimeter or Area to measure again.")
            : Kind() == MeasureKind.Distance
            ? Loc.T("Click the two ends. Hold Shift for straight lines.")
            : Loc.T("Click each corner, then double-click to finish. Hold Shift for straight lines.");
        if (tool is null || tool.Points.Count == 0)
        {
            Readout.Text = "—";
            return;
        }
        var points = tool.Points.ToList();
        if (tool.Hover is { } hover && tool.HoverPage == tool.Page) points.Add(hover);
        Readout.Text = points.Count < 2 ? "—" : new MeasureItem(tool.Kind, tool.Page, points).Value(_scale);
    }
}
