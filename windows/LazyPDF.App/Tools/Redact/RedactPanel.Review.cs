// Looking the marks over: the list with its jump and remove, and the boxes drawn on the pages.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace LazyPDF.App.Tools.Redact;

public partial class RedactPanel
{
    private static readonly Brush MarkFill = Frozen(Color.FromArgb(0x55, 0xC4, 0x2B, 0x1C));
    private static readonly Brush MarkStroke = Frozen(Color.FromRgb(0xC4, 0x2B, 0x1C));

    private sealed record Drawn(Panel Layer, IReadOnlyList<MarkItem> Items, List<UIElement> Shapes);

    private readonly Dictionary<int, Drawn> _drawn = [];

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private void ShowMarks()
    {
        var items = _state!.Marks.Items;
        MarkedList.ItemsSource = items.ToList();
        MarkedHeader.Text = Loc.Plural(items.Count, "{0} mark", "{0} marks");
        bool any = items.Count > 0;
        MarkedList.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        ClearButton.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmptyNote.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        DrawOverlays(redrawAll: false);
    }

    // The viewer may have rebuilt its layers (redrawAll); otherwise only the pages whose marks changed are drawn again.
    private void DrawOverlays(bool redrawAll)
    {
        if (redrawAll) ClearOverlays();
        if (Viewer is not { } viewer || _state is null) return;
        var byPage = _state.Marks.Items.Where(m => m.Page < viewer.PageCount).GroupBy(m => m.Page).ToDictionary(g => g.Key, g => (IReadOnlyList<MarkItem>)g.ToList());
        foreach (int page in _drawn.Keys.Where(p => !byPage.ContainsKey(p)).ToList()) Erase(page);
        foreach (var (page, items) in byPage)
        {
            if (_drawn.TryGetValue(page, out var drawn))
            {
                if (drawn.Items.SequenceEqual(items)) continue;
                Erase(page);
            }
            var layer = viewer.Overlay(page);
            var geometry = viewer.Geometry(page);
            var shapes = new List<UIElement>();
            foreach (var quad in items.SelectMany(m => m.Mark.Quads))
            {
                var shape = new Polygon { Points = MarkShapes.Outline(geometry, quad), Fill = MarkFill, Stroke = MarkStroke, StrokeThickness = 1, IsHitTestVisible = false };
                layer.Children.Add(shape);
                shapes.Add(shape);
            }
            _drawn[page] = new Drawn(layer, items, shapes);
        }
    }

    private void Erase(int page)
    {
        foreach (var shape in _drawn[page].Shapes) _drawn[page].Layer.Children.Remove(shape);
        _drawn.Remove(page);
    }

    private void ClearOverlays()
    {
        foreach (int page in _drawn.Keys.ToList()) Erase(page);
    }

    private void MarkedList_SelectionChanged(object sender, SelectionChangedEventArgs e) => Jump();

    // A click on the row that is already selected raises no selection change.
    private void MarkedItem_Click(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && FindAncestor<Button>(source) is null) Jump();
    }

    private void Jump()
    {
        if (MarkedList.SelectedItem is not MarkItem item || Viewer is not { } viewer || item.Page >= viewer.PageCount) return;
        viewer.GoToPage(item.Page);
        viewer.Reveal(item.Page, MarkShapes.Where(viewer.Geometry(item.Page), item.Mark));
    }

    private static T? FindAncestor<T>(DependencyObject element) where T : DependencyObject
    {
        for (var node = element; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is T found) return found;
        }
        return null;
    }

    private void MarkedList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Delete || MarkedList.SelectedItem is not MarkItem item) return;
        RemoveOne(item);
        e.Handled = true;
    }

    private void RemoveMark_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is MarkItem item) RemoveOne(item);
    }

    private void RemoveOne(MarkItem item)
    {
        var marks = _state!.Marks;
        var index = MarkedList.Items.IndexOf(item);
        marks.Remove(item);
        Host!.ShowNotice(Loc.T("Mark removed"), Loc.T("It is off the list."),
                         new NoticeAction(Loc.T("Put it back"), PutBack([item])));
        FocusNeighbour(index);
    }

    private void FocusNeighbour(int index)
    {
        if (MarkedList.Items.Count == 0)
        {
            DrawToggle.Focus();
            return;
        }
        index = Math.Clamp(index, 0, MarkedList.Items.Count - 1);
        MarkedList.SelectedIndex = index;
        MarkedList.UpdateLayout();
        (MarkedList.ItemContainerGenerator.ContainerFromIndex(index) as FrameworkElement)?.Focus();
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        var marks = _state!.Marks;
        var removed = marks.Items.ToList();
        marks.Clear();
        Host!.ShowNotice(Loc.Plural(removed.Count, "{0} mark removed", "{0} marks removed"), Loc.T("The list is empty now."),
                         new NoticeAction(Loc.T("Put them back"), PutBack(removed)));
    }

    // The marks keep page numbers, so they go back only while the pages are as they were.
    private Action PutBack(IReadOnlyList<MarkItem> items)
    {
        var state = _state!;
        var pages = state.Pages;
        return () =>
        {
            if (pages is not null && pages.SequenceEqual(state.Pages ?? [])) state.Marks.Add(items);
            else Host!.ShowNotice(Loc.T("Marks removed"), Loc.T("The pages changed, so the marks no longer fit. Mark them again."));
        };
    }
}
