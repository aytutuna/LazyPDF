using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Redact;

/// <summary>Shows a frame with handles over the selected box mark; dragging it moves the box, dragging a handle resizes it.</summary>
public sealed class RedactBoxEditor
{
    // A shape has no automation peer, so the outline sits in a border that carries the name screen readers read on focus.
    private sealed class Frame : Border
    {
        public Frame()
        {
            Line = SignatureBoxTool.Outline();
            Child = Line;
            IsHitTestVisible = false;
        }

        public Rectangle Line { get; }

        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

        private sealed class Peer(Frame owner) : FrameworkElementAutomationPeer(owner)
        {
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

            protected override string GetClassNameCore() => nameof(Frame);
        }
    }

    public enum Handle { Body, TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left }

    private const double Smallest = 4;
    private const double ThumbSize = 12;

    private readonly IDocumentViewer _viewer;
    private readonly Action<MarkItem, MarkItem> _changed;
    private readonly Action<string> _status;
    private readonly Action _leave;
    private readonly DispatcherTimer _settle = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly List<(Handle Handle, Thumb Thumb)> _thumbs = [];
    private MarkItem? _item;
    private PageOverlay? _layer;
    private Frame? _frame;
    private Rect _rect;
    private Rect _start;
    private Point _grab;
    private bool _nudging;
    private bool _resized;

    public RedactBoxEditor(IDocumentViewer viewer, Action<MarkItem, MarkItem> changed, Action<string> status, Action leave)
    {
        _viewer = viewer;
        _changed = changed;
        _status = status;
        _leave = leave;
        _settle.Tick += (_, _) =>
        {
            Commit();
            _frame?.Focus();
        };
        viewer.ViewChanged += Viewer_ViewChanged;
    }

    public void Detach()
    {
        _viewer.ViewChanged -= Viewer_ViewChanged;
        Show(null);
    }

    /// <summary>Frames <paramref name="item"/> when it is a box; null, or any other mark, removes the frame.</summary>
    public void Show(MarkItem? item)
    {
        Clear();
        if (item is not { IsBox: true } || item.Page >= _viewer.PageCount) return;
        _item = item;
        _layer = _viewer.Overlay(item.Page);
        _rect = MarkShapes.Where(_viewer.Geometry(item.Page), item.Mark);
        _frame = new Frame();
        _frame.Focusable = true;
        _frame.FocusVisualStyle = null;
        AutomationProperties.SetName(_frame, Loc.T("Box on page {0}. Arrow keys move it. Control and arrow keys resize it. Escape returns to the list.", item.Page + 1));
        _frame.KeyDown += Frame_KeyDown;
        _frame.GotKeyboardFocus += (_, _) => _frame.Line.StrokeThickness = 3;
        _frame.LostKeyboardFocus += (_, _) =>
        {
            Commit();
            if (_frame is not null) _frame.Line.StrokeThickness = 1.5;
        };
        _layer.Children.Add(_frame);
        foreach (var handle in Enum.GetValues<Handle>()) Add(handle);
        Place();
    }

    /// <summary>Gives the frame keyboard focus; false when no box is framed.</summary>
    public bool Focus() => _frame?.Focus() ?? false;

    public void Clear()
    {
        Commit();
        _nudging = false;
        if (_layer is not null)
        {
            if (_frame is not null) _layer.Children.Remove(_frame);
            foreach (var (_, thumb) in _thumbs) _layer.Children.Remove(thumb);
        }
        _thumbs.Clear();
        _frame = null;
        _layer = null;
        _item = null;
    }

    /// <summary>The box after a drag of <paramref name="delta"/> (page space) on <paramref name="handle"/>, kept on the page and at least <paramref name="smallest"/> across.</summary>
    public static Rect Drag(Rect rect, Handle handle, Vector delta, Size page, double smallest = Smallest)
    {
        if (handle == Handle.Body)
        {
            double x = Math.Clamp(rect.X + delta.X, 0, Math.Max(0, page.Width - rect.Width));
            double y = Math.Clamp(rect.Y + delta.Y, 0, Math.Max(0, page.Height - rect.Height));
            return new Rect(x, y, rect.Width, rect.Height);
        }
        double left = rect.Left, top = rect.Top, right = rect.Right, bottom = rect.Bottom;
        if (handle is Handle.TopLeft or Handle.Left or Handle.BottomLeft) left = Math.Clamp(left + delta.X, 0, Math.Max(0, right - smallest));
        if (handle is Handle.TopRight or Handle.Right or Handle.BottomRight) right = Math.Clamp(right + delta.X, left + smallest, Math.Max(left + smallest, page.Width));
        if (handle is Handle.TopLeft or Handle.Top or Handle.TopRight) top = Math.Clamp(top + delta.Y, 0, Math.Max(0, bottom - smallest));
        if (handle is Handle.BottomLeft or Handle.Bottom or Handle.BottomRight) bottom = Math.Clamp(bottom + delta.Y, top + smallest, Math.Max(top + smallest, page.Height));
        return new Rect(left, top, right - left, bottom - top);
    }

    /// <summary>The box after an arrow key: it moves, with Control the right and bottom edges move instead; Shift makes the step 10 instead of 1.</summary>
    public static Rect Nudge(Rect rect, Key key, ModifierKeys modifiers, Size page)
    {
        double step = modifiers.HasFlag(ModifierKeys.Shift) ? 10 : 1;
        var delta = key switch
        {
            Key.Left => new Vector(-step, 0),
            Key.Right => new Vector(step, 0),
            Key.Up => new Vector(0, -step),
            _ => new Vector(0, step),
        };
        if (!modifiers.HasFlag(ModifierKeys.Control)) return Drag(rect, Handle.Body, delta, page);
        return Drag(rect, key is Key.Left or Key.Right ? Handle.Right : Handle.Bottom, delta, page);
    }

    private void Add(Handle handle)
    {
        var thumb = new Thumb
        {
            Cursor = Cursor(handle),
            Template = new ControlTemplate(typeof(Thumb)) { VisualTree = Visual(handle) },
        };
        thumb.DragStarted += (_, _) => { Commit(); _start = _rect; _grab = Mouse.GetPosition(_layer); };
        thumb.DragDelta += (_, _) => Dragged(handle);
        thumb.DragCompleted += (_, e) => Done(e.Canceled);
        _layer!.Children.Add(thumb);
        _thumbs.Add((handle, thumb));
    }

    private static FrameworkElementFactory Visual(Handle handle)
    {
        var square = new FrameworkElementFactory(typeof(Rectangle));
        square.SetValue(Shape.FillProperty, handle == Handle.Body ? Brushes.Transparent : Brushes.White);
        if (handle == Handle.Body) return square;
        square.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        square.SetValue(Shape.StrokeThicknessProperty, 1.0);
        return square;
    }

    private void Dragged(Handle handle)
    {
        var delta = Mouse.GetPosition(_layer) - _grab;
        _rect = Drag(_start, handle, delta, _viewer.PageSize(_item!.Page));
        Place();
    }

    private void Frame_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Commit();
            _leave();
        }
        else if (e.Key is Key.Left or Key.Right or Key.Up or Key.Down)
        {
            if (_thumbs.Any(t => t.Thumb.IsDragging)) return;
            var modifiers = Keyboard.Modifiers;
            if (!_nudging)
            {
                _nudging = true;
                _resized = false;
                _start = _rect;
            }
            _resized |= modifiers.HasFlag(ModifierKeys.Control);
            _rect = Nudge(_rect, e.Key, modifiers, _viewer.PageSize(_item!.Page));
            Place();
            _settle.Stop();
            _settle.Start();
        }
        else return;
        e.Handled = true;
    }

    // One replace for a whole run of key presses, so Undo takes the run back in one step.
    private void Commit()
    {
        _settle.Stop();
        if (!_nudging) return;
        _nudging = false;
        if (_rect == _start) return;
        Done(false);
        _status(_resized ? Loc.T("Box resized.") : Loc.T("Box moved."));
    }

    private void Done(bool canceled)
    {
        if (_item is not { } old) return;
        if (canceled)
        {
            _rect = _start;
            Place();
            return;
        }
        if (_rect == _start) return;
        var geometry = _viewer.Geometry(old.Page);
        var now = old with { Mark = MarkShapes.Box(old.Page, geometry, _rect.TopLeft, _rect.BottomRight) };
        _changed(old, now);
    }

    // The layer is scaled with the page, so the handles are divided by the zoom to stay the same size on screen.
    private void Place()
    {
        SignatureBoxTool.Place(_frame!, _rect);
        double size = ThumbSize / _viewer.Zoom;
        foreach (var (handle, thumb) in _thumbs)
        {
            if (handle == Handle.Body)
            {
                thumb.Width = _rect.Width;
                thumb.Height = _rect.Height;
                Canvas.SetLeft(thumb, _rect.X);
                Canvas.SetTop(thumb, _rect.Y);
                continue;
            }
            var centre = Centre(handle);
            thumb.Width = size;
            thumb.Height = size;
            Canvas.SetLeft(thumb, centre.X - size / 2);
            Canvas.SetTop(thumb, centre.Y - size / 2);
        }
    }

    private Point Centre(Handle handle)
    {
        double x = handle switch
        {
            Handle.TopLeft or Handle.Left or Handle.BottomLeft => _rect.Left,
            Handle.TopRight or Handle.Right or Handle.BottomRight => _rect.Right,
            _ => _rect.Left + _rect.Width / 2,
        };
        double y = handle switch
        {
            Handle.TopLeft or Handle.Top or Handle.TopRight => _rect.Top,
            Handle.BottomLeft or Handle.Bottom or Handle.BottomRight => _rect.Bottom,
            _ => _rect.Top + _rect.Height / 2,
        };
        return new Point(x, y);
    }

    private static Cursor Cursor(Handle handle) => handle switch
    {
        Handle.Body => Cursors.SizeAll,
        Handle.Top or Handle.Bottom => Cursors.SizeNS,
        Handle.Left or Handle.Right => Cursors.SizeWE,
        Handle.TopLeft or Handle.BottomRight => Cursors.SizeNWSE,
        _ => Cursors.SizeNESW,
    };

    private void Viewer_ViewChanged(object? sender, EventArgs e)
    {
        if (_frame is not null) Place();
    }
}
