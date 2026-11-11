using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Services;

namespace LazyPDF.App;

/// <summary>A recent file on the Home tab, with its thumbnail once that is drawn.</summary>
public sealed class RecentCard(RecentItem item) : INotifyPropertyChanged
{
    private ImageSource? _thumbnail;

    public RecentItem Item { get; } = item;

    /// <summary>When it was opened and where it is, or that it is gone.</summary>
    public string Caption { get; } = item.Exists ? $"{item.Opened} · {item.Folder}" : Loc.T("Not found");

    public ImageSource? Thumbnail
    {
        get => _thumbnail;
        set
        {
            _thumbnail = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}

public partial class HomeView : UserControl
{
    // A tile and a recent card are both 168 wide with a margin of 6 on each side.
    private const double SlotWidth = 168 + 12;

    private readonly ObservableCollection<RecentCard> _cards = [];
    private IReadOnlyList<HomeTile> _tiles = [];

    public HomeView()
    {
        InitializeComponent();
        RecentGrid.ItemsSource = _cards;
    }

    /// <summary>Draws the pictures of recent files; without it the cards show an icon.</summary>
    public Thumbnails? Thumbnails { get; set; }

    public event EventHandler<string>? TileChosen;

    public event EventHandler<string>? FileChosen;

    public event EventHandler<string>? FileForgotten;

    public event EventHandler? RecentCleared;

    public void Show(IReadOnlyList<HomeTile> tiles, IReadOnlyList<RecentItem> recent)
    {
        if (!_tiles.SequenceEqual(tiles))
        {
            _tiles = tiles;
            TileGrid.ItemsSource = tiles;
        }
        if (!_cards.Select(c => c.Item).SequenceEqual(recent))
        {
            _cards.Clear();
            foreach (var item in recent)
            {
                var card = new RecentCard(item);
                _cards.Add(card);
                if (item.Exists) _ = LoadThumbnailAsync(card);
            }
        }
        RecentHeader.Visibility = _cards.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoRecent.Visibility = _cards.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private async Task LoadThumbnailAsync(RecentCard card)
    {
        if (Thumbnails is null || await Thumbnails.GetAsync(card.Item.Path) is not { } png || !_cards.Contains(card)) return;
        using var stream = new MemoryStream(png);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        card.Thumbnail = image;
    }

    /// <summary>Puts keyboard focus on the first tile that can be started, so Enter carries on from Home.</summary>
    public void FocusDefaultTile()
    {
        TileGrid.UpdateLayout();
        for (int i = 0; i < _tiles.Count; i++)
        {
            if (!_tiles[i].Available || TileGrid.ItemContainerGenerator.ContainerFromIndex(i) is not ContentPresenter presenter) continue;
            if (VisualTreeHelper.GetChildrenCount(presenter) > 0 && VisualTreeHelper.GetChild(presenter, 0) is Button tile) tile.Focus();
            return;
        }
    }

    private void Tile_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is HomeTile tile) TileChosen?.Invoke(this, tile.Id);
    }

    private void Recent_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is RecentCard card) FileChosen?.Invoke(this, card.Item.Path);
    }

    private void RemoveRecent_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is RecentCard card) FileForgotten?.Invoke(this, card.Item.Path);
    }

    private void ClearRecent_Click(object sender, RoutedEventArgs e) => RecentCleared?.Invoke(this, EventArgs.Empty);

    private void Scroller_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var (cards, header) = GridInsets.For(e.NewSize.Width, slotWidth: SlotWidth);
        TileGrid.Margin = cards;
        RecentGrid.Margin = cards;
        TitleLabel.Margin = header with { Top = 20, Bottom = 8 };
        RecentHeader.Margin = header with { Top = 24, Bottom = 4 };
    }
}
