using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// Layers in the view. A toggle is not an edit: the pages are drawn from a copy of the file with the layer changed,
// so the file, its undo history and its unsaved mark stay as they are.
public partial class PageViewer
{
    private readonly Dictionary<PdfReference, bool> _layerChanges = [];
    private WindowsPageRenderer? _displayRenderer;
    private PdfEditSession? _displaySession;
    private int _layerTicket;

    public event EventHandler? LayersChanged;

    public LayerSet Layers => _tab is null ? new LayerSet([], []) : PdfLayers.Read(_displaySession?.Document ?? _tab.Document);

    public void SetLayerVisible(PdfReference layer, bool visible) => SetLayersVisible([new(layer, visible)]);

    public void SetLayersVisible(IEnumerable<KeyValuePair<PdfReference, bool>> changes)
    {
        if (_tab is null) return;
        var set = PdfLayers.Read(_tab.Document);
        var batch = changes.ToList();
        // Turning a layer on turns off its radio group. Recording that as well keeps a stored change for another
        // member from outliving the choice when the chosen layer is already on in the file.
        var named = batch.Select(c => c.Key).ToHashSet();
        foreach (var (layer, visible) in batch.ToArray())
        {
            if (!visible) continue;
            foreach (var group in set.RadioGroups.Where(g => g.Any(r => r.Equals(layer))))
            {
                foreach (var other in group.Where(r => !r.Equals(layer) && named.Add(r))) batch.Add(new(other, false));
            }
        }
        foreach (var (layer, visible) in batch)
        {
            if (visible == (set.Layers.FirstOrDefault(l => l.Reference.Equals(layer))?.IsOn ?? visible)) _layerChanges.Remove(layer);
            else _layerChanges[layer] = visible;
        }
        _ = RebuildDisplayAsync();
    }

    private void ResetLayers()
    {
        _layerChanges.Clear();
        _layerTicket++;
        Surface.SetDisplay(null);
        DropDisplay();
    }

    // The file changed: the layers the person switched are switched again on the new state.
    private void ReapplyLayers()
    {
        if (_layerChanges.Count == 0) return;
        _ = RebuildDisplayAsync();
    }

    private void DropDisplay()
    {
        _displayRenderer?.Dispose();
        _displayRenderer = null;
        _displaySession = null;
    }

    private async Task RebuildDisplayAsync()
    {
        int ticket = ++_layerTicket;
        if (_tab is not { } tab) return;
        if (_layerChanges.Count == 0)
        {
            Surface.SetDisplay(null);
            DropDisplay();
            LayersChanged?.Invoke(this, EventArgs.Empty);
            return;
        }
        var bytes = PageSurface.Bytes(tab);
        string? password = tab.Password;
        var certificate = tab.Certificate;
        var changes = _layerChanges.ToArray();
        var copy = await Task.Run(() => DisplayCopy.Create(bytes, password, changes, certificate));
        if (ticket != _layerTicket)
        {
            copy?.Renderer.Dispose();
            return;
        }
        if (copy is null)
        {
            // The pages were given new versions by the reload; showing them from the old copy would keep the edit out.
            Surface.SetDisplay(null);
            DropDisplay();
            LayersChanged?.Invoke(this, EventArgs.Empty);
            return;
        }
        var old = _displayRenderer;
        (_displaySession, _displayRenderer) = (copy.Session, copy.Renderer);
        Surface.SetDisplay(copy.Renderer);
        old?.Dispose();
        LayersChanged?.Invoke(this, EventArgs.Empty);
    }
}
