using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

/// <summary>What the pointer does on the pages.</summary>
internal enum EditMode
{
    /// <summary>Click an object, drag to move it or to select several, drag a handle to resize.</summary>
    Select,

    /// <summary>Drag the box of a new text.</summary>
    TextBox,

    /// <summary>Drag the area of a new link, or click one to change it.</summary>
    Link,

    /// <summary>Drag the part of the selected picture to keep.</summary>
    Crop,
}

/// <summary>
/// The pointer tool of the panel and what it draws on the pages: the selection with its handles, the area being
/// dragged, the links. It only reports what the person did; the panel makes the edits, so that it knows which of the
/// document's changes are its own.
/// </summary>
internal sealed partial class EditSurface(IDocumentViewer viewer, PageEdits edits) : IPagePointerTool
{
    private enum Gesture
    {
        None,
        Band,
        Move,
        Resize,
    }

    // Screen pixels: how far the pointer goes before a press is a drag, and how near a handle it has to be.
    private const double Slop = 4;
    private const double Reach = 8;
    private const double MinSize = 2;

    private readonly List<int> _selected = [];
    private EditMode _mode;
    private Gesture _gesture;
    private int _gesturePage;
    private Point _start, _now;
    private Rect _origin;
    private int _handle;
    private bool _moved, _square, _extend;
    private PageObject? _pressed;
    private PdfLink? _pressedLink;

    public Cursor? Cursor => _mode == EditMode.Select ? null : Cursors.Cross;

    /// <summary>The page of the selection, or -1.</summary>
    public int Page { get; private set; } = -1;

    public IReadOnlyList<int> Selected => _selected;

    public EditMode Mode
    {
        get => _mode;
        set
        {
            if (_mode == value) return;
            _mode = value;
            _gesture = Gesture.None;
            ShowArea(-1, null);
            RedrawAll();
        }
    }

    /// <summary>A press is about to start something; the panel finishes what it had open first.</summary>
    public event EventHandler? Pressing;

    public event EventHandler? SelectionChanged;

    /// <summary>A click on text: the page, the object and the place in page space.</summary>
    public event Action<int, int, Point>? TextClicked;

    /// <summary>An area was dragged in the Text box, Link or Crop mode; in user space.</summary>
    public event Action<int, PdfRect>? AreaDrawn;

    public event Action<int, PdfLink?>? LinkPicked;

    public event Action<int, IReadOnlyList<int>, double, double>? MoveRequested;

    public event Action<int, IReadOnlyList<int>, PdfRect>? ResizeRequested;

    public void Select(int page, IEnumerable<int> ids)
    {
        int oldPage = Page;
        var chosen = ids.ToList();
        _selected.Clear();
        _selected.AddRange(chosen);
        Page = chosen.Count == 0 ? -1 : page;
        Redraw(oldPage);
        Redraw(Page);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Clear() => Select(-1, []);

    /// <summary>The document changed: drops ids that are gone and draws again.</summary>
    public void Refresh()
    {
        if (Page >= 0) _selected.RemoveAll(id => edits.Object(Page, id) is null);
        if (_selected.Count == 0) Page = -1;
        RedrawAll();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Press(PagePointer p)
    {
        Pressing?.Invoke(this, EventArgs.Empty);
        _gesturePage = p.Page;
        _start = _now = p.Point;
        _moved = false;
        _pressed = null;
        _pressedLink = null;
        _gesture = Gesture.Band;
        if (_mode == EditMode.Link)
        {
            _pressedLink = LinkAt(p.Page, p.Point);
            return;
        }
        if (_mode != EditMode.Select) return;

        bool shift = _extend = p.Modifiers.HasFlag(ModifierKeys.Shift);
        if (_selected.Count > 0 && p.Page == Page)
        {
            var bounds = SelectionBounds();
            int handle = HandleAt(bounds, p.Point, ViewScale.Of(viewer, p.Page));
            if (handle >= 0)
            {
                (_gesture, _handle, _origin) = (Gesture.Resize, handle, bounds);
                return;
            }
            if (!shift && bounds.Contains(p.Point))
            {
                (_gesture, _pressed) = (Gesture.Move, Hit(p.Page, p.Point));
                return;
            }
        }
        var hit = Hit(p.Page, p.Point);
        if (hit is null)
        {
            if (!shift) Clear();
            return;
        }
        if (shift && p.Page == Page)
        {
            if (!_selected.Remove(hit.Id)) _selected.Add(hit.Id);
            Select(p.Page, [.. _selected]);
        }
        else Select(p.Page, [hit.Id]);
        (_gesture, _pressed) = (Gesture.Move, hit);
    }

    public void Move(PagePointer p)
    {
        if (!p.Pressed || _gesture == Gesture.None || p.Page != _gesturePage) return;
        _now = p.Point;
        _square = !p.Modifiers.HasFlag(ModifierKeys.Shift);
        if (!_moved && (_now - _start).Length * ViewScale.Of(viewer, p.Page) > Slop) _moved = true;
        Redraw(_gesturePage);
    }

    public void Release(PagePointer p)
    {
        var gesture = _gesture;
        _gesture = Gesture.None;
        if (p.Page == _gesturePage) _now = p.Point;
        int page = _gesturePage;
        switch (gesture)
        {
            case Gesture.Band:
                FinishBand(page);
                break;
            case Gesture.Move when !_moved:
                if (!_extend && _pressed is TextObject text) TextClicked?.Invoke(page, text.Id, _start);
                break;
            case Gesture.Move:
                var from = viewer.Geometry(page).ToUser(_start.X, _start.Y);
                var to = viewer.Geometry(page).ToUser(_now.X, _now.Y);
                MoveRequested?.Invoke(page, [.. _selected], to.X - from.X, to.Y - from.Y);
                break;
            case Gesture.Resize when _moved:
                ResizeRequested?.Invoke(page, [.. _selected], UserRect(page, Resized()));
                break;
        }
        Redraw(page);
    }

    public void Cancel()
    {
        _gesture = Gesture.None;
        RedrawAll();
    }

    /// <summary>Leaves the pages as they were.</summary>
    public void Detach()
    {
        _gesture = Gesture.None;
        _selected.Clear();
        Page = -1;
        viewer.ViewChanged -= Viewer_ViewChanged;
        if (ReferenceEquals(viewer.PointerTool, this)) viewer.PointerTool = null;
        RemoveChrome();
    }

    private void FinishBand(int page)
    {
        if (_mode == EditMode.Link && !_moved && _pressedLink is { } link)
        {
            LinkPicked?.Invoke(page, link);
            return;
        }
        if (!_moved) return;
        var band = Rect.Intersect(Rect.Union(new Rect(_start, _start), new Rect(_now, _now)), new Rect(viewer.PageSize(page)));
        if (band.IsEmpty) return;
        if (_mode == EditMode.Select)
        {
            var found = edits.Editor(page).Select(UserRect(page, band)).Where(o => !IsBackdrop(page, o)).Select(o => o.Id);
            Select(page, found);
        }
        else if (band.Width >= 6 && band.Height >= 6) AreaDrawn?.Invoke(page, UserRect(page, band));
    }

    private PageObject? Hit(int page, Point at)
    {
        var (x, y) = viewer.Geometry(page).ToUser(at.X, at.Y);
        var hit = edits.Editor(page).HitTest(x, y, Reach / 2 / ViewScale.Of(viewer, page));
        return hit is null || IsBackdrop(page, hit) ? null : hit;
    }

    // A path as big as the page is its background; grabbing it by mistake would carry the whole page along.
    private bool IsBackdrop(int page, PageObject o)
    {
        var size = viewer.PageSize(page);
        return o is PathObject && o.Bounds.Width * o.Bounds.Height >= 0.8 * size.Width * size.Height;
    }

    private PdfLink? LinkAt(int page, Point at)
    {
        var (x, y) = viewer.Geometry(page).ToUser(at.X, at.Y);
        return edits.Links(page).LastOrDefault(l => x >= l.Rect.Left && x <= l.Rect.Right && y >= l.Rect.Bottom && y <= l.Rect.Top);
    }

    private Rect PageRect(int page, PdfRect user)
    {
        var d = viewer.Geometry(page).ToDisplay(user);
        return new Rect(d.X, d.Y, d.Width, d.Height);
    }

    private PdfRect UserRect(int page, Rect shown) =>
        viewer.Geometry(page).ToUser(new DisplayRect(shown.X, shown.Y, shown.Width, shown.Height));

    private Rect SelectionBounds()
    {
        var bounds = Rect.Empty;
        foreach (int id in _selected)
        {
            if (edits.Object(Page, id) is { } o) bounds.Union(PageRect(Page, o.Bounds));
        }
        return bounds;
    }

    // The handles run round the box from the top left: corners at 0, 2, 4, 6 and sides at 1, 3, 5, 7.
    private static Point[] Handles(Rect r) =>
    [
        r.TopLeft, new(r.X + r.Width / 2, r.Top), r.TopRight, new(r.Right, r.Y + r.Height / 2),
        r.BottomRight, new(r.X + r.Width / 2, r.Bottom), r.BottomLeft, new(r.Left, r.Y + r.Height / 2),
    ];

    internal static int HandleAt(Rect bounds, Point at, double scale)
    {
        var handles = Handles(bounds);
        for (int i = 0; i < handles.Length; i++)
        {
            if (Math.Abs(handles[i].X - at.X) * scale <= Reach && Math.Abs(handles[i].Y - at.Y) * scale <= Reach) return i;
        }
        return -1;
    }

    private Rect Resized() => Resize(_origin, _handle, _now, _square);

    // The box with the dragged handle at the pointer and the opposite side held; corners keep the proportions when asked.
    internal static Rect Resize(Rect origin, int handle, Point now, bool square)
    {
        double left = origin.Left, top = origin.Top, right = origin.Right, bottom = origin.Bottom;
        if (handle is 0 or 6 or 7) left = Math.Min(now.X, right - MinSize);
        if (handle is 2 or 3 or 4) right = Math.Max(now.X, left + MinSize);
        if (handle is 0 or 1 or 2) top = Math.Min(now.Y, bottom - MinSize);
        if (handle is 4 or 5 or 6) bottom = Math.Max(now.Y, top + MinSize);
        if (handle % 2 == 0 && square)
        {
            double width = right - left, height = width * origin.Height / origin.Width;
            if (handle is 0 or 2) top = bottom - height;
            else bottom = top + height;
        }
        return new Rect(new Point(left, top), new Point(right, bottom));
    }
}
