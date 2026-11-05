using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace LazyPDF.App.Tools.Pages;

/// <summary>
/// Dragging the selected pages of a grid to a new place, with a mark on the tile where they would land. A grid that
/// takes files lets them be dropped between its pages in the same way.
/// </summary>
internal sealed class PageDrag
{
    public const string Format = "LazyPDF.Pages";

    private readonly ListBox _grid;
    private readonly Func<List<PageCell>> _cells;
    private readonly Func<List<int>> _selected;
    private readonly Action<int[], int> _move;
    private readonly Action<string[], int>? _files;

    private Point _pressAt;
    private PageCell? _pressed;
    private bool _keptSelection;
    private PageCell? _marked;

    /// <param name="move">Gets the pages and the index they go before.</param>
    /// <param name="files">Gets dropped file paths and the index they go before; null when the grid takes no files.</param>
    public PageDrag(ListBox grid, Func<List<PageCell>> cells, Func<List<int>> selected, Action<int[], int> move, Action<string[], int>? files = null)
    {
        _grid = grid;
        _cells = cells;
        _selected = selected;
        _move = move;
        _files = files;
        grid.PreviewMouseLeftButtonDown += Grid_PreviewMouseLeftButtonDown;
        grid.PreviewMouseLeftButtonUp += Grid_PreviewMouseLeftButtonUp;
        grid.PreviewMouseMove += Grid_PreviewMouseMove;
        grid.DragOver += Grid_DragOver;
        grid.DragLeave += Grid_DragLeave;
        grid.Drop += Grid_Drop;
    }

    private PageCell? CellAt(object source) =>
        source is DependencyObject element && ItemsControl.ContainerFromElement(_grid, element) is ListBoxItem { DataContext: PageCell cell } ? cell : null;

    private void Grid_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _pressed = e.OriginalSource is DependencyObject source && Ancestor<System.Windows.Controls.Primitives.ButtonBase>(source) is null ? CellAt(e.OriginalSource) : null;
        _pressAt = e.GetPosition(_grid);
        _keptSelection = false;
        // Pressing on one of several selected pages must not drop the others yet: it may be the start of a drag.
        if (_pressed is null || Keyboard.Modifiers != ModifierKeys.None || _grid.SelectedItems.Count < 2 || !_grid.SelectedItems.Contains(_pressed)) return;
        _keptSelection = true;
        _grid.Focus();
        e.Handled = true;
    }

    private void Grid_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_keptSelection && _pressed is { } cell)
        {
            _grid.SelectedItems.Clear();
            _grid.SelectedItems.Add(cell);
        }
        _pressed = null;
        _keptSelection = false;
    }

    private void Grid_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _pressed is null) return;
        var moved = e.GetPosition(_grid) - _pressAt;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _pressed = null;
        _keptSelection = false;
        DragDrop.DoDragDrop(_grid, new DataObject(Format, _selected().ToArray()), DragDropEffects.Move);
        Unmark();
    }

    private void Grid_DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        bool pages = e.Data.GetDataPresent(Format);
        if (!pages && !(_files is not null && e.Data.GetDataPresent(DataFormats.FileDrop)))
        {
            e.Effects = DragDropEffects.None;
            return;
        }
        e.Effects = pages ? DragDropEffects.Move : DragDropEffects.Copy;
        Unmark();
        var cells = _cells();
        if (Descendant<TilePanel>(_grid) is { } tiles && cells.Count > 0)
        {
            var (index, after) = tiles.CellAt(e.GetPosition(tiles));
            _marked = cells[index];
            if (after) _marked.DropAfter = true;
            else _marked.DropBefore = true;
        }
        Scroll(e.GetPosition(_grid).Y);
    }

    private void Grid_DragLeave(object sender, DragEventArgs e) => Unmark();

    private void Grid_Drop(object sender, DragEventArgs e)
    {
        int before = _marked is null ? _cells().Count : _marked.DropAfter ? _marked.Index + 1 : _marked.Index;
        Unmark();
        if (e.Data.GetData(Format) is int[] pages && pages.Length > 0) _move(pages, before);
        else if (_files is not null && e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0) _files(paths, before);
        e.Handled = true;
    }

    private void Unmark()
    {
        if (_marked is null) return;
        _marked.DropBefore = false;
        _marked.DropAfter = false;
        _marked = null;
    }

    // The grid follows a drag that reaches its top or bottom edge.
    private void Scroll(double y)
    {
        if (Descendant<ScrollViewer>(_grid) is not { } scroll) return;
        if (y < 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset - 24);
        else if (y > _grid.ActualHeight - 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset + 24);
    }

    internal static T? Descendant<T>(DependencyObject parent) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T found) return found;
            if (Descendant<T>(child) is { } inner) return inner;
        }
        return null;
    }

    internal static T? Ancestor<T>(DependencyObject node) where T : DependencyObject
    {
        for (var current = node; current is not null; current = current is Visual ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current))
        {
            if (current is T found) return found;
        }
        return null;
    }
}
