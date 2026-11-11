using System.ComponentModel;
using System.Windows.Media;
using LazyPDF.App.Services;

namespace LazyPDF.App.Panels.Pages;

/// <summary>
/// One page in the thumbnail list. The picture is made the first time the list asks for it and let go of when the
/// row scrolls away, so a long file holds only the thumbnails near the window.
/// </summary>
public sealed class PageThumb(int index, string label, double width, double height, double dpi, int objectNumber, WindowsPageRenderer? renderer) : INotifyPropertyChanged
{
    // Thumbnails are drawn two at a time, so scrolling a long list does not queue the whole file.
    private static readonly SemaphoreSlim Turns = new(2);

    private ImageSource? _image;
    private ImageSource? _stale;
    private int _ticket;
    private bool _loading;
    private bool _dropBefore;
    private bool _dropAfter;

    public int Index { get; } = index;

    public int ObjectNumber { get; } = objectNumber;

    public string Label { get; } = label;

    public string Name { get; } = Loc.T("Page {0}", label);

    public double Width { get; } = width;

    public double Height { get; } = height;

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

    public ImageSource? Image
    {
        get
        {
            if (_image is null && !_loading && renderer is not null) _ = LoadAsync();
            return _image ?? _stale;
        }
    }

    /// <summary>Shows the picture of the thumb this one replaces until its own is made.</summary>
    public void Inherit(PageThumb old)
    {
        if (old.ObjectNumber == ObjectNumber && old.Width == Width && old.Height == Height) _stale = old._image ?? old._stale;
    }

    /// <summary>Drops the picture; asking for it again makes it again.</summary>
    public void Release()
    {
        _ticket++;
        _loading = false;
        _image = null;
        _stale = null;
    }

    private async Task LoadAsync()
    {
        _loading = true;
        int ticket = _ticket;
        ImageSource? image = null;
        await Turns.WaitAsync();
        try
        {
            if (ticket == _ticket) image = await Task.Run(async () => await renderer!.RenderAsync(Index, dpi) is { } pixels ? Pixels.ToBitmap(pixels) : null);
        }
        finally
        {
            Turns.Release();
        }
        if (ticket != _ticket) return;
        // A page that could not be drawn stays marked as loading, so the list does not ask again and again.
        _image = image;
        _stale = null;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image)));
    }

    private void Set(ref bool field, bool value, string name)
    {
        if (field == value) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
