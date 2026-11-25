using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Layers;

/// <summary>A layer, or a heading that groups layers, in the tree.</summary>
public sealed class LayerRow(string name, PdfLayer? layer, List<LayerRow> children, bool radio = false) : INotifyPropertyChanged
{
    private bool _on = layer?.IsOn ?? false;

    public string Name { get; } = name;

    public PdfLayer? Layer { get; } = layer;

    public List<LayerRow> Children { get; } = children;

    public bool CanToggle => Layer is { Locked: false };

    public string? LockedTip => Layer is { Locked: true } ? Loc.T("The file does not allow this layer to be shown or hidden.") : null;

    /// <summary>The layer belongs to a radio button group of the file: it shows a round button, and choosing it turns the others of the group off.</summary>
    public bool IsRadio { get; } = radio && layer is not null;

    public Visibility CheckVisibility => Layer is null || IsRadio ? Visibility.Collapsed : Visibility.Visible;

    public Visibility RadioVisibility => IsRadio ? Visibility.Visible : Visibility.Collapsed;

    public Visibility LabelVisibility => Layer is null ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Raised when the person ticks or clears the box, not when the panel follows the view.</summary>
    public event Action<LayerRow>? Toggled;

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsChecked
    {
        get => _on;
        set
        {
            if (_on == value) return;
            _on = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
            Toggled?.Invoke(this);
        }
    }

    public void Follow(bool on)
    {
        if (_on == on) return;
        _on = on;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
    }
}

/// <summary>The layers of the file, each with a box. Ticking one changes what the viewer draws, not the file.</summary>
public partial class LayersSidePanel : ToolPanel
{
    private readonly List<LayerRow> _rows = [];
    private HashSet<PdfReference> _radios = [];

    public LayersSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        Viewer!.LayersChanged += Viewer_LayersChanged;
        Tab!.Changed += Tab_Changed;
        Build();
    }

    protected override void OnDetach()
    {
        Viewer!.LayersChanged -= Viewer_LayersChanged;
        Tab!.Changed -= Tab_Changed;
        Tree.ItemsSource = null;
        _rows.Clear();
    }

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Build()
    {
        var set = Viewer!.Layers;
        _rows.Clear();
        _radios = [.. set.RadioGroups.SelectMany(g => g)];
        List<LayerRow> roots = set.Order.Count > 0 ? [.. set.Order.Select(Row)] : [.. set.Layers.Select(l => Row(new LayerNode(null, l, [])))];
        Tree.ItemsSource = roots;
        Empty.Visibility = set.Layers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Tree.Visibility = set.Layers.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Actions.Visibility = Tree.Visibility;
        RefreshButtons();
    }

    private void RefreshButtons()
    {
        var layers = Viewer!.Layers.Layers;
        ShowAllButton.IsEnabled = layers.Any(l => !l.Locked && !l.IsOn);
        HideAllButton.IsEnabled = layers.Any(l => !l.Locked && l.IsOn);
        var inFile = PdfLayers.Read(Tab!.Document).Layers.ToDictionary(l => l.Reference, l => l.IsOn);
        ResetButton.IsEnabled = layers.Any(l => inFile.TryGetValue(l.Reference, out bool on) && on != l.IsOn);
    }

    private void ShowAll_Click(object sender, RoutedEventArgs e) => SetAll(_ => true);

    private void HideAll_Click(object sender, RoutedEventArgs e) => SetAll(_ => false);

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        var inFile = PdfLayers.Read(Tab!.Document).Layers.ToDictionary(l => l.Reference, l => l.IsOn);
        SetAll(l => inFile.GetValueOrDefault(l.Reference, l.IsOn));
    }

    private void SetAll(Func<PdfLayer, bool> state) =>
        Viewer!.SetLayersVisible(Viewer.Layers.Layers.Where(l => !l.Locked).Select(l => new KeyValuePair<PdfReference, bool>(l.Reference, state(l))));

    private LayerRow Row(LayerNode node)
    {
        var row = new LayerRow(node.Layer?.Name ?? (string.IsNullOrWhiteSpace(node.Label) ? Loc.T("Group") : node.Label), node.Layer, [.. node.Children.Select(Row)], node.Layer is { } l && _radios.Contains(l.Reference));
        row.Toggled += Row_Toggled;
        _rows.Add(row);
        return row;
    }

    private void Row_Toggled(LayerRow row)
    {
        if (row.Layer is { } layer) Viewer?.SetLayerVisible(layer.Reference, row.IsChecked);
    }

    // Focus sits on the tree item, not the box inside it, so the space bar does the ticking.
    private void Tree_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Space || Keyboard.Modifiers != ModifierKeys.None || Tree.SelectedItem is not LayerRow { CanToggle: true } row) return;
        if (e.IsRepeat)
        {
            e.Handled = true;
            return;
        }
        row.IsChecked = row.IsRadio || !row.IsChecked;
        e.Handled = true;
    }

    // The view changed the layers (a radio group, or the file itself): the boxes follow.
    private void Viewer_LayersChanged(object? sender, EventArgs e)
    {
        var state = Viewer!.Layers.Layers.ToDictionary(l => l.Reference, l => l.IsOn);
        foreach (var row in _rows)
        {
            if (row.Layer is { } layer && state.TryGetValue(layer.Reference, out bool on)) row.Follow(on);
        }
        RefreshButtons();
    }
}
