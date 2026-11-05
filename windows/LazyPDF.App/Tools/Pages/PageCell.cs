using System.ComponentModel;
using System.Windows.Media;
using LazyPDF.App.Services;

namespace LazyPDF.App.Tools.Pages;

/// <summary>
/// One page in the organize grid. The picture is made when the panel asks for it, for the rows in view, and let go
/// of when they scroll away; the marks show where a dragged page would land.
/// </summary>
public sealed class PageCell(int index, string label, double width, double height, double scale) : INotifyPropertyChanged
{
    // Two at a time, so a long file does not queue every page.
    private static readonly SemaphoreSlim Turns = new(2);

    private ImageSource? _image;
    private int _ticket;
    private bool _loading;
    private bool _dropBefore;
    private bool _dropAfter;

    public int Index { get; } = index;

    public string Label { get; } = label;

    public string Name { get; } = Loc.T("Page {0}", label);

    public double Width { get; private set; } = width;

    public double Height { get; private set; } = height;

    /// <summary>Size of the picture in pixels per point of the page.</summary>
    public double Scale { get; private set; } = scale;

    public ImageSource? Image => _image;

    public bool DropBefore
    {
        get => _dropBefore;
        set => Set(ref _dropBefore, value, nameof(DropBefore));
    }

    public bool DropAfter
    {
        get => _dropAfter;
        set => Set(ref _dropAfter, value, nameof(DropAfter));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public async Task LoadAsync(WindowsPageRenderer renderer, double dpi)
    {
        if (_image is not null || _loading) return;
        _loading = true;
        int ticket = _ticket;
        ImageSource? image = null;
        await Turns.WaitAsync();
        try
        {
            if (ticket == _ticket) image = await Task.Run(async () => await renderer.RenderAsync(Index, dpi) is { } pixels ? Pixels.ToBitmap(pixels) : null);
        }
        finally
        {
            Turns.Release();
        }
        if (ticket != _ticket) return;
        // A page that cannot be drawn stays marked as loading, so it is not asked for again.
        _image = image;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image)));
    }

    /// <summary>Changes the size the cell is drawn at; the picture it has stays until the grid asks for a sharper one.</summary>
    public void Refit(double width, double height, double scale)
    {
        Width = width;
        Height = height;
        Scale = scale;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    public void Release()
    {
        if (_image is null && !_loading) return;
        _ticket++;
        _loading = false;
        _image = null;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image)));
    }

    private void Set(ref bool field, bool value, string name)
    {
        if (field == value) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
