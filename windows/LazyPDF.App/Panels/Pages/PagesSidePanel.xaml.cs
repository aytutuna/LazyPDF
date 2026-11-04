using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;

namespace LazyPDF.App.Panels.Pages;

/// <summary>Every page as a small picture, the page in view marked; a click goes to the page. The list shows only the rows in view.</summary>
public partial class PagesSidePanel : ToolPanel
{
    private const double BoxWidth = 132;
    private const double BoxHeight = 190;

    private bool _syncing;

    public PagesSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        Viewer!.PageChanged += Viewer_PageChanged;
        Tab!.Changed += Tab_Changed;
        Build();
    }

    protected override void OnDetach()
    {
        Viewer!.PageChanged -= Viewer_PageChanged;
        Tab!.Changed -= Tab_Changed;
        Thumbs.ItemsSource = null;
    }

    private void Build()
    {
        var tab = Tab!;
        var viewer = Viewer!;
        var renderer = tab.Renderer as WindowsPageRenderer;
        double dpr = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var items = new List<PageThumb>(viewer.PageCount);
        for (int i = 0; i < viewer.PageCount; i++)
        {
            var size = viewer.PageSize(i);
            double scale = Math.Min(BoxWidth / Math.Max(size.Width, 1), BoxHeight / Math.Max(size.Height, 1));
            items.Add(new PageThumb(i, viewer.PageLabel(i), Math.Round(size.Width * scale), Math.Round(size.Height * scale), scale * 72 * dpr, renderer));
        }
        _syncing = true;
        Thumbs.ItemsSource = items;
        _syncing = false;
        Mark();
    }

    // The page in view gets the ring and is scrolled into the list.
    private void Mark()
    {
        if (Viewer is not { } viewer || Thumbs.Items.Count == 0) return;
        int page = Math.Clamp(viewer.PageIndex, 0, Thumbs.Items.Count - 1);
        if (Thumbs.SelectedIndex == page) return;
        _syncing = true;
        Thumbs.SelectedIndex = page;
        _syncing = false;
        Thumbs.ScrollIntoView(Thumbs.SelectedItem);
    }

    private void Viewer_PageChanged(object? sender, EventArgs e) => Mark();

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Thumbs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || Thumbs.SelectedIndex < 0 || Viewer is not { } viewer) return;
        if (viewer.PageIndex != Thumbs.SelectedIndex) viewer.GoToPage(Thumbs.SelectedIndex);
    }

    private void Thumb_Unloaded(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is PageThumb thumb) thumb.Release();
    }
}
