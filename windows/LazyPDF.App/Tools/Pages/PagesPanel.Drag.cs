// Dragging the selected pages to a new place in the grid.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace LazyPDF.App.Tools.Pages;

public partial class PagesPanel
{
    private const string DragFormat = "LazyPDF.Pages";

    private Point _pressAt;
    private PageCell? _pressed;
    private bool _keptSelection;
    private PageCell? _marked;

    private PageCell? CellAt(object source) =>
        source is DependencyObject element && ItemsControl.ContainerFromElement(Thumbs, element) is ListBoxItem { DataContext: PageCell cell } ? cell : null;

    private void Thumbs_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _pressed = CellAt(e.OriginalSource);
        _pressAt = e.GetPosition(Thumbs);
        _keptSelection = false;
        // Pressing on one of several selected pages must not drop the others yet: it may be the start of a drag.
        if (_pressed is null || Keyboard.Modifiers != ModifierKeys.None || Thumbs.SelectedItems.Count < 2 || !Thumbs.SelectedItems.Contains(_pressed)) return;
        _keptSelection = true;
        Thumbs.Focus();
        e.Handled = true;
    }

    private void Thumbs_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_keptSelection && _pressed is { } cell)
        {
            Thumbs.SelectedItems.Clear();
            Thumbs.SelectedItems.Add(cell);
        }
        _pressed = null;
        _keptSelection = false;
    }

    private void Thumbs_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _pressed is null) return;
        var moved = e.GetPosition(Thumbs) - _pressAt;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _pressed = null;
        _keptSelection = false;
        DragDrop.DoDragDrop(Thumbs, new DataObject(DragFormat, Selected().ToArray()), DragDropEffects.Move);
        Unmark();
    }

    private void Thumbs_DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (!e.Data.GetDataPresent(DragFormat))
        {
            e.Effects = DragDropEffects.None;
            return;
        }
        e.Effects = DragDropEffects.Move;
        Unmark();
        if (Descendant<TilePanel>(Thumbs) is { } tiles && Cells.Count > 0)
        {
            var (index, after) = tiles.CellAt(e.GetPosition(tiles));
            _marked = Cells[index];
            if (after) _marked.DropAfter = true;
            else _marked.DropBefore = true;
        }
        Scroll(e.GetPosition(Thumbs).Y);
    }

    private void Thumbs_DragLeave(object sender, DragEventArgs e) => Unmark();

    private void Thumbs_Drop(object sender, DragEventArgs e)
    {
        int before = _marked is null ? Cells.Count : _marked.DropAfter ? _marked.Index + 1 : _marked.Index;
        Unmark();
        if (e.Data.GetData(DragFormat) is int[] pages && pages.Length > 0) MoveTo(pages, before);
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
        if (Scroller() is not { } scroll) return;
        if (y < 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset - 24);
        else if (y > Thumbs.ActualHeight - 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset + 24);
    }
}
