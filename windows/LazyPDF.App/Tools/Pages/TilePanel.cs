using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace LazyPDF.App.Tools.Pages;

/// <summary>
/// Rows of equal cells, left to right, of which only those in view have a container. A file of thousands of pages
/// costs a screenful of tiles, and the scroll bar still spans all of it.
/// </summary>
internal sealed class TilePanel : VirtualizingPanel, IScrollInfo
{
    public static readonly DependencyProperty CellWidthProperty = DependencyProperty.Register(
        nameof(CellWidth), typeof(double), typeof(TilePanel), new FrameworkPropertyMetadata(100.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty CellHeightProperty = DependencyProperty.Register(
        nameof(CellHeight), typeof(double), typeof(TilePanel), new FrameworkPropertyMetadata(100.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    private Size _viewport;
    private Size _extent;
    private double _offset;
    private int _columns = 1;

    public double CellWidth
    {
        get => (double)GetValue(CellWidthProperty);
        set => SetValue(CellWidthProperty, value);
    }

    public double CellHeight
    {
        get => (double)GetValue(CellHeightProperty);
        set => SetValue(CellHeightProperty, value);
    }

    /// <summary>The cell a point falls in or is nearest to, and whether it is in the right half of it; the point is in the panel's own space, so scrolling is counted in.</summary>
    public (int Index, bool After) CellAt(Point point) =>
        Locate(point, _offset, CellWidth, CellHeight, _columns, ItemCount);

    /// <summary>The first and last cell in view, widened by <paramref name="spareRows"/> rows each way.</summary>
    public (int First, int Last) Window(int spareRows)
    {
        int first = Math.Max(0, (int)(_offset / CellHeight) - spareRows) * _columns;
        int last = ((int)((_offset + _viewport.Height) / CellHeight) + 1 + spareRows) * _columns - 1;
        return (first, Math.Min(last, ItemCount - 1));
    }

    public static (int Index, bool After) Locate(Point point, double offset, double cellWidth, double cellHeight, int columns, int count)
    {
        if (count == 0) return (0, false);
        int row = Math.Max(0, (int)((point.Y + offset) / cellHeight));
        int column = Math.Clamp((int)(point.X / cellWidth), 0, columns - 1);
        int index = row * columns + column;
        if (index >= count) return (count - 1, true);
        return (index, point.X - column * cellWidth > cellWidth / 2);
    }

    private int ItemCount => ItemsControl.GetItemsOwner(this)?.Items.Count ?? 0;

    protected override Size MeasureOverride(Size available)
    {
        int count = ItemCount;
        _columns = double.IsInfinity(available.Width) ? 1 : Math.Max(1, (int)(available.Width / CellWidth));
        int rows = (count + _columns - 1) / _columns;
        var extent = new Size(_columns * CellWidth, rows * CellHeight);
        var viewport = new Size(available.Width, double.IsInfinity(available.Height) ? extent.Height : available.Height);
        _offset = Math.Clamp(_offset, 0, Math.Max(0, extent.Height - viewport.Height));

        int first = count == 0 ? 0 : Math.Min(count - 1, (int)(_offset / CellHeight) * _columns);
        int last = Math.Min(count - 1, ((int)Math.Ceiling((_offset + viewport.Height) / CellHeight)) * _columns - 1);
        Realize(first, last);

        if (extent != _extent || viewport != _viewport)
        {
            _extent = extent;
            _viewport = viewport;
            ScrollOwner?.InvalidateScrollInfo();
        }
        return viewport;
    }

    private void Realize(int first, int last)
    {
        // The generator only exists once the children have been asked for.
        _ = InternalChildren;
        var generator = ItemContainerGenerator;
        if (last >= first)
        {
            var start = generator.GeneratorPositionFromIndex(first);
            int child = start.Offset == 0 ? start.Index : start.Index + 1;
            using (generator.StartAt(start, GeneratorDirection.Forward, true))
            {
                for (int index = first; index <= last; index++, child++)
                {
                    var tile = (UIElement)generator.GenerateNext(out bool isNew);
                    if (isNew)
                    {
                        if (child >= InternalChildren.Count) AddInternalChild(tile);
                        else InsertInternalChild(child, tile);
                        generator.PrepareItemContainer(tile);
                    }
                    tile.Measure(new Size(CellWidth, CellHeight));
                }
            }
        }
        for (int i = InternalChildren.Count - 1; i >= 0; i--)
        {
            var position = new GeneratorPosition(i, 0);
            int index = generator.IndexFromGeneratorPosition(position);
            if (index >= first && index <= last) continue;
            generator.Remove(position, 1);
            RemoveInternalChildRange(i, 1);
        }
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            int index = ItemContainerGenerator.IndexFromGeneratorPosition(new GeneratorPosition(i, 0));
            InternalChildren[i].Arrange(new Rect(index % _columns * CellWidth, index / _columns * CellHeight - _offset, CellWidth, CellHeight));
        }
        return finalSize;
    }

    protected override void OnItemsChanged(object sender, ItemsChangedEventArgs args)
    {
        switch (args.Action)
        {
            case System.Collections.Specialized.NotifyCollectionChangedAction.Remove:
            case System.Collections.Specialized.NotifyCollectionChangedAction.Replace:
                RemoveInternalChildRange(args.Position.Index, args.ItemUICount);
                break;
            case System.Collections.Specialized.NotifyCollectionChangedAction.Move:
                RemoveInternalChildRange(args.OldPosition.Index, args.ItemUICount);
                break;
        }
        InvalidateMeasure();
    }

    protected override void BringIndexIntoView(int index)
    {
        double top = index / _columns * CellHeight;
        if (top < _offset) SetVerticalOffset(top);
        else if (top + CellHeight > _offset + _viewport.Height) SetVerticalOffset(top + CellHeight - _viewport.Height);
    }

    public bool CanHorizontallyScroll { get; set; }

    public bool CanVerticallyScroll { get; set; }

    public double ExtentWidth => _extent.Width;

    public double ExtentHeight => _extent.Height;

    public double ViewportWidth => _viewport.Width;

    public double ViewportHeight => _viewport.Height;

    public double HorizontalOffset => 0;

    public double VerticalOffset => _offset;

    public ScrollViewer? ScrollOwner { get; set; }

    public void SetVerticalOffset(double offset)
    {
        offset = Math.Clamp(offset, 0, Math.Max(0, _extent.Height - _viewport.Height));
        if (offset == _offset) return;
        _offset = offset;
        InvalidateMeasure();
        ScrollOwner?.InvalidateScrollInfo();
    }

    public void SetHorizontalOffset(double offset)
    {
    }

    public void LineUp() => SetVerticalOffset(_offset - 16);

    public void LineDown() => SetVerticalOffset(_offset + 16);

    public void LineLeft()
    {
    }

    public void LineRight()
    {
    }

    public void PageUp() => SetVerticalOffset(_offset - _viewport.Height);

    public void PageDown() => SetVerticalOffset(_offset + _viewport.Height);

    public void PageLeft()
    {
    }

    public void PageRight()
    {
    }

    public void MouseWheelUp() => SetVerticalOffset(_offset - 48);

    public void MouseWheelDown() => SetVerticalOffset(_offset + 48);

    public void MouseWheelLeft()
    {
    }

    public void MouseWheelRight()
    {
    }

    public Rect MakeVisible(Visual visual, Rect rectangle)
    {
        int child = visual is UIElement tile ? InternalChildren.IndexOf(tile) : -1;
        if (child >= 0) BringIndexIntoView(ItemContainerGenerator.IndexFromGeneratorPosition(new GeneratorPosition(child, 0)));
        return rectangle;
    }
}
