using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// The pointer and the keyboard on the pages: Hand pans, Select selects text, a pointer tool takes the button from both.
// A click on a link follows it in either mode.
public partial class PageViewer
{
    private enum Drag
    {
        None,
        Pan,
        Select,
        Area,
        Tool,
    }

    private const double ClickSlop = 4;

    private readonly Dictionary<int, IReadOnlyList<PdfLink>> _links = [];
    private readonly DispatcherTimer _autoScroll = new() { Interval = TimeSpan.FromMilliseconds(30) };
    private readonly System.Windows.Controls.ToolTip _linkTip = new() { Placement = System.Windows.Controls.Primitives.PlacementMode.Relative };
    private (int Page, PdfLink Link)? _focusLink;
    private PointerMode _mode = PointerMode.Select;
    private PointerMode _modeBeforeArea = PointerMode.Select;
    private IPagePointerTool? _tool;
    private Drag _drag;
    private HwndSource? _hooked;
    private int _dragPage;
    private Point _down, _last;
    private PdfLink? _downLink;
    private bool _moved;
    private bool _linkClick;
    private bool _middlePan;

    public event EventHandler? ModeChanged;

    public PointerMode Mode
    {
        get => _mode;
        set
        {
            if (value == _mode && _tool is null) return;
            _mode = value;
            CancelPendingSelection();
            PointerTool = null;
            ModeChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public IPagePointerTool? PointerTool
    {
        get => _tool;
        set
        {
            if (ReferenceEquals(value, _tool)) return;
            EndPointerTool();
            _tool = value;
            if (value is not null && _mode is PointerMode.Zoom or PointerMode.Snapshot) _mode = _modeBeforeArea;
            Surface.Cursor = value?.Cursor;
            RefreshBar();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SetMode(PointerMode mode)
    {
        if (mode == _mode && _tool is null)
        {
            RefreshBar();
            return;
        }
        Mode = mode;
        RefreshBar();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void EndPointerTool()
    {
        CancelPendingSelection();
        StopSpeech();
        EndKeyPlacement();
        if (_drag == Drag.Tool)
        {
            _drag = Drag.None;
            Surface.ReleaseMouseCapture();
        }
        _tool?.Cancel();
    }

    private void InitInput()
    {
        _autoScroll.Tick += (_, _) => AutoScrollStep();
        _hidePointer.Tick += (_, _) => HidePointer();
        PreviewMouseMove += (_, _) => ShowPointer();
        Surface.MouseLeftButtonDown += Surface_MouseDown;
        Surface.PreviewMouseRightButtonDown += (_, _) => Surface.Focus();
        Surface.MouseMove += Surface_MouseMove;
        Surface.MouseLeave += (_, _) => _linkTip.IsOpen = false;
        Surface.MouseLeftButtonUp += Surface_MouseUp;
        Surface.MouseDown += Surface_ExtraButtonDown;
        Surface.MouseUp += Surface_MiddleButtonUp;
        Surface.LostMouseCapture += Surface_LostMouseCapture;
        Surface.PreviewMouseWheel += Surface_MouseWheel;
        Loaded += (_, _) =>
        {
            _hooked?.RemoveHook(TiltHook);
            _hooked = PresentationSource.FromVisual(this) as HwndSource;
            _hooked?.AddHook(TiltHook);
        };
        Unloaded += (_, _) =>
        {
            _hooked?.RemoveHook(TiltHook);
            _hooked = null;
        };
        Surface.KeyDown += Surface_KeyDown;
        Surface.ManipulationStarting += (_, e) =>
        {
            e.ManipulationContainer = Surface;
            e.Mode = ManipulationModes.Scale | ManipulationModes.Translate;
            e.Handled = true;
        };
        Surface.ManipulationInertiaStarting += (_, e) => e.TranslationBehavior.DesiredDeceleration = 0.003;
        Surface.ManipulationDelta += Surface_ManipulationDelta;
    }

    private void Surface_ContextMenuOpening(object sender, System.Windows.Controls.ContextMenuEventArgs e)
    {
        if (_tab is null || _presenting || _tool is not null || _drag != Drag.None)
        {
            e.Handled = true;
            return;
        }
        CopyItem.IsEnabled = HasSelection && CanCopy;
        BackItem.IsEnabled = CanGoBack;
        ForwardItem.IsEnabled = CanGoForward;
    }

    private void CopyItem_Click(object sender, RoutedEventArgs e) => _ = CopySelectionAsync();

    private void SelectAllItem_Click(object sender, RoutedEventArgs e) => SelectAll();

    private void BackItem_Click(object sender, RoutedEventArgs e) => GoBack();

    private void ForwardItem_Click(object sender, RoutedEventArgs e) => GoForward();

    private void FindItem_Click(object sender, RoutedEventArgs e) => ShowFind();

    private PagePointer Pointer(PagePoint hit, Point surfacePoint, int clicks, bool pressed) =>
        new(hit.Page, hit.Point, Surface.TranslatePoint(surfacePoint, this), pressed, clicks, Keyboard.Modifiers);

    private void Surface_MouseDown(object sender, MouseButtonEventArgs e)
    {
        _linkTip.IsOpen = false;
        Surface.Focus();
        ClearLinkFocus();
        if (_tab is null) return;
        if (_presenting)
        {
            _down = e.GetPosition(Surface);
            _moved = false;
            _presentDown = true;
            Surface.CaptureMouse();
            e.Handled = true;
            return;
        }
        if (_middlePan)
        {
            e.Handled = true;
            return;
        }
        var clicks = e.ClickCount;
        if (_linkClick && clicks == 2)
        {
            // The first click of a double click jumped to a link; the second lands on the new page.
            _downLink = null;
            e.Handled = true;
            return;
        }
        if (_linkClick)
        {
            // A third quick press at the same spot is a new click, e.g. a "next" link in the same place on every page.
            _linkClick = false;
            clicks = 1;
        }
        var at = e.GetPosition(Surface);
        var hit = Surface.Hit(at);
        _down = _last = at;
        _moved = false;
        _downLink = hit is { } h ? LinkAt(h.Page, h.Point) : null;
        if (_tool is { } tool)
        {
            if (hit is not { } over) return;
            _drag = Drag.Tool;
            _dragPage = over.Page;
            Surface.CaptureMouse();
            tool.Press(Pointer(new PagePoint(over.Page, over.Point), at, clicks, true));
        }
        else if (_mode is PointerMode.Zoom or PointerMode.Snapshot)
        {
            if (Surface.Hit(at, true) is not { } over) return;
            _drag = Drag.Area;
            _dragPage = over.Page;
            Surface.CaptureMouse();
            Surface.Cursor = Cursors.Cross;
        }
        else if (_mode == PointerMode.Hand)
        {
            _drag = Drag.Pan;
            Surface.CaptureMouse();
            Surface.Cursor = Cursors.ScrollAll;
        }
        else
        {
            _drag = Drag.Select;
            Surface.CaptureMouse();
            BeginSelection(at, clicks);
            _autoScroll.Start();
        }
        e.Handled = true;
    }

    private void Surface_ExtraButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_drag != Drag.None) return;
        switch (e.ChangedButton)
        {
            case MouseButton.XButton1:
                GoBack();
                e.Handled = true;
                break;
            case MouseButton.XButton2:
                GoForward();
                e.Handled = true;
                break;
            case MouseButton.Right when _presenting:
                StepPage(-1);
                e.Handled = true;
                break;
            case MouseButton.Middle when _tab is not null && !_presenting:
                Surface.Focus();
                _drag = Drag.Pan;
                _middlePan = true;
                _down = _last = e.GetPosition(Surface);
                _moved = false;
                _downLink = null;
                Surface.CaptureMouse();
                Surface.Cursor = Cursors.ScrollAll;
                e.Handled = true;
                break;
        }
    }

    private void Surface_MiddleButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Middle || !_middlePan) return;
        EndDrag();
        Surface.ReleaseMouseCapture();
        Hover(e.GetPosition(Surface));
        e.Handled = true;
    }

    private void Surface_MouseMove(object sender, MouseEventArgs e)
    {
        var at = e.GetPosition(Surface);
        if (_presenting)
        {
            if (_presentDown && (at - _down).Length > ClickSlop) _moved = true;
            return;
        }
        if (_drag != Drag.None && (at - _down).Length > ClickSlop) _moved = true;
        switch (_drag)
        {
            case Drag.Pan:
                Surface.ScrollBy(_last.X - at.X, _last.Y - at.Y);
                break;
            case Drag.Select:
                DragSelection(at);
                break;
            case Drag.Area:
                Surface.Marquee = new Rect(_down, at);
                break;
            case Drag.Tool:
                if (Surface.PageMatrix(_dragPage) is { } matrix)
                {
                    matrix.Invert();
                    _tool?.Move(Pointer(new PagePoint(_dragPage, matrix.Transform(at)), at, 0, true));
                }
                break;
            default:
                Hover(at);
                break;
        }
        _last = at;
    }

    private void Surface_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_presentDown)
        {
            _presentDown = false;
            Surface.ReleaseMouseCapture();
            var press = e.GetPosition(Surface);
            if (!_moved)
            {
                if (Surface.Hit(press) is { } over && LinkAt(over.Page, over.Point) is { } target) FollowLink(target);
                else StepPage(1);
            }
            e.Handled = true;
            return;
        }
        if (_middlePan)
        {
            e.Handled = true;
            return;
        }
        var drag = _drag;
        var snapshot = _mode == PointerMode.Snapshot;
        var at = e.GetPosition(Surface);
        if (drag == Drag.Tool)
        {
            if (Surface.PageMatrix(_dragPage) is { } matrix)
            {
                matrix.Invert();
                _tool?.Release(Pointer(new PagePoint(_dragPage, matrix.Transform(at)), at, 0, false));
            }
            else
            {
                // The page the press began on is no longer laid out, so there is no place to release at.
                _tool?.Cancel();
            }
        }
        EndDrag();
        Surface.ReleaseMouseCapture();
        if (drag == Drag.Area)
        {
            if (snapshot) SnapshotDrag(new Rect(_down, at));
            else ZoomToDrag(new Rect(_down, at), at);
        }
        if (drag is Drag.Pan or Drag.Select && !_moved && _downLink is { } link)
        {
            _linkClick = true;
            FollowLink(link);
        }
        Hover(at);
        e.Handled = true;
    }

    // The capture went somewhere else (another window, a popup) while the button was down: the tool gets no release.
    private void Surface_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_drag == Drag.Tool) _tool?.Cancel();
        EndDrag();
    }

    // One shot: the mode before comes back whether the drag zoomed or not.
    private void ZoomToDrag(Rect box, Point at)
    {
        SetMode(_modeBeforeArea);
        if (ZoomMath.IsClick(box))
        {
            Surface.SetZoom(ZoomMath.Step(Surface.Zoom, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : 1), at);
            return;
        }
        if (DraggedArea(box) is { } area) Surface.ZoomToArea(_dragPage, area);
    }

    // One shot like the zoom; a box under 8 points is a slip of the hand.
    private void SnapshotDrag(Rect box)
    {
        SetMode(_modeBeforeArea);
        if (DraggedArea(box) is { Width: >= 8, Height: >= 8 } area) _ = CopyAreaAsync(_dragPage, area);
    }

    private Rect? DraggedArea(Rect box)
    {
        if (Surface.PageMatrix(_dragPage) is not { } matrix) return null;
        matrix.Invert();
        var area = Rect.Intersect(PageSpace.Transform(matrix, box), new Rect(Surface.PageSize(_dragPage)));
        return area.IsEmpty ? null : area;
    }

    private void EndDrag()
    {
        Surface.Marquee = null;
        _drag = Drag.None;
        _middlePan = false;
        _presentDown = false;
        _anchorWaiting = null;
        _autoScroll.Stop();
    }

    // The cursor over what is under the pointer: a link, text to select, or the tool's own.
    private void Hover(Point at)
    {
        if (_tool is not null)
        {
            Surface.Cursor = _tool.Cursor;
            _linkTip.IsOpen = false;
            if (Surface.Hit(at) is { } over && Surface.PageMatrix(over.Page) is not null)
                _tool.Move(Pointer(new PagePoint(over.Page, over.Point), at, 0, false));
            return;
        }
        var hit = Surface.Hit(at);
        var link = hit is { } h ? LinkAt(h.Page, h.Point) : null;
        var tip = link is null ? null : LinkTip(link);
        if (tip is null) _linkTip.IsOpen = false;
        else
        {
            _linkTip.HorizontalOffset = at.X + 12;
            _linkTip.VerticalOffset = at.Y + 18;
            if (!Equals(_linkTip.Content, tip) || !_linkTip.IsOpen)
            {
                _linkTip.Content = tip;
                _linkTip.PlacementTarget = Surface;
                _linkTip.IsOpen = true;
            }
        }
        if (_mode is PointerMode.Zoom or PointerMode.Snapshot) Surface.Cursor = Cursors.Cross;
        else if (link is not null) Surface.Cursor = Cursors.Hand;
        else if (_mode == PointerMode.Hand) Surface.Cursor = Cursors.Hand;
        else Surface.Cursor = hit is { } t && IsOverText(t.Page, t.Point) ? Cursors.IBeam : null;
    }

    private string? LinkTip(PdfLink link)
    {
        if (_tab is null) return null;
        if (link.Action is UriAction uri)
        {
            return WebAddress(uri.Uri);
        }
        var destination = link.Action is GoToAction go ? go.Destination : link.Action is null ? link.Destination : null;
        if (destination is null || PdfDestinations.Locate(_tab.Document, destination) is not { } place) return null;
        return Loc.T("Go to page {0}", PageLabel(place.PageIndex));
    }

    private IReadOnlyList<PdfLink> LinksOf(int page)
    {
        if (!_links.TryGetValue(page, out var links)) _links[page] = links = PdfLinks.Read(_tab!.Document, _tab.Document.Pages[page]);
        return links;
    }

    private PdfLink? LinkAt(int page, Point point)
    {
        if (_tab is null) return null;
        var links = LinksOf(page);
        if (links.Count == 0) return null;
        var (x, y) = Surface.Geometry(page).ToUser(point.X, point.Y);
        return links.FirstOrDefault(l => x >= l.Rect.Left && x <= l.Rect.Right && y >= l.Rect.Bottom && y <= l.Rect.Top);
    }

    private void ClearLinkFocus()
    {
        if (_focusLink is null) return;
        _focusLink = null;
        Surface.InvalidateVisual();
    }

    // Moves the focus ring to the next (or previous) link in reading order; false once it leaves the ends.
    private bool TabToLink(bool backwards)
    {
        if (_tab is null) return false;
        var all = new List<(int Page, PdfLink Link, DisplayRect Area)>();
        foreach (int page in VisiblePages)
        {
            var geometry = Surface.Geometry(page);
            foreach (var link in LinksOf(page)) all.Add((page, link, geometry.ToDisplay(link.Rect)));
        }
        all.Sort((a, b) => a.Page != b.Page ? a.Page.CompareTo(b.Page)
            : a.Area.Y != b.Area.Y ? a.Area.Y.CompareTo(b.Area.Y) : a.Area.X.CompareTo(b.Area.X));
        int at = _focusLink is { } current ? all.FindIndex(l => l.Page == current.Page && ReferenceEquals(l.Link, current.Link)) : -1;
        int next = at < 0 ? (backwards ? all.Count - 1 : 0) : at + (backwards ? -1 : 1);
        if (next < 0 || next >= all.Count)
        {
            ClearLinkFocus();
            return false;
        }
        var target = all[next];
        FocusLink(target.Page, target.Link, new Rect(target.Area.X, target.Area.Y, target.Area.Width, target.Area.Height));
        Speak(LinkTip(target.Link) ?? Loc.T("Link"));
        return true;
    }

    private void FocusLink(int page, PdfLink link, Rect area)
    {
        _focusLink = (page, link);
        Surface.Reveal(page, area);
        Surface.InvalidateVisual();
    }

    // The links of a page as screen readers see them.
    private IReadOnlyList<LinkTarget> LinkTargets(int page)
    {
        if (_tab is null) return [];
        var geometry = Surface.Geometry(page);
        return [.. LinksOf(page).Select(link =>
        {
            var area = geometry.ToDisplay(link.Rect);
            var rect = new Rect(area.X, area.Y, area.Width, area.Height);
            return new LinkTarget(rect, LinkTip(link) ?? Loc.T("Link"), () => FollowLink(link), () => FocusLink(page, link, rect));
        })];
    }

    private void FollowLink(PdfLink link)
    {
        if (link.Action is { } action) FollowAction(action);
        else if (link.Destination is { } destination) GoToDestination(destination);
    }

    private void AutoScrollStep()
    {
        if (_drag != Drag.Select) return;
        var at = Mouse.GetPosition(Surface);
        double dy = at.Y < 0 ? at.Y : at.Y > Surface.ActualHeight ? at.Y - Surface.ActualHeight : 0;
        double dx = at.X < 0 ? at.X : at.X > Surface.ActualWidth ? at.X - Surface.ActualWidth : 0;
        if (dx == 0 && dy == 0) return;
        Surface.ScrollBy(dx / 3, dy / 3);
        DragSelection(at);
    }

    // The window procedure must return TRUE for a driver to repeat a held tilt.
    private IntPtr TiltHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != 0x020E || _presenting || !Surface.IsMouseOver || Surface.Layout.PageCount == 0) return IntPtr.Zero;
        double notches = (short)((wParam.ToInt64() >> 16) & 0xFFFF) / 120.0;
        int lines = SystemParameters.WheelScrollLines;
        Surface.ScrollBy(notches * (lines < 0 ? Surface.Viewport.Width * 0.9 : lines * 24), 0, smooth: false);
        handled = true;
        return new IntPtr(1);
    }

    private void Surface_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_presenting)
        {
            _wheel += e.Delta;
            for (; Math.Abs(_wheel) >= 120; _wheel -= Math.Sign(_wheel) * 120) StepPage(_wheel < 0 ? 1 : -1);
        }
        else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            Surface.SetZoom(Surface.Zoom * Math.Pow(1.1, e.Delta / 120.0), e.GetPosition(Surface));
        }
        else
        {
            double notches = e.Delta / 120.0;
            int lines = SystemParameters.WheelScrollLines;
            double distance = notches * (lines < 0 ? Surface.Viewport.Height * 0.9 : lines * 24);
            bool smooth = e.Delta % 120 != 0;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) Surface.ScrollBy(-distance, 0, smooth);
            else Surface.ScrollBy(0, -distance, smooth);
        }
        e.Handled = true;
    }

    private void Surface_ManipulationDelta(object? sender, ManipulationDeltaEventArgs e)
    {
        var delta = e.DeltaManipulation;
        if (Math.Abs(delta.Scale.X - 1) > 0.001) Surface.SetZoom(Surface.Zoom * delta.Scale.X, e.ManipulationOrigin);
        Surface.ScrollBy(-delta.Translation.X, -delta.Translation.Y);
        e.Handled = true;
    }

    // ----- Keys

    // Keys that work wherever the focus is in the viewer.
    private void Viewer_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_tab is null) return;
        var mods = Keyboard.Modifiers;
        // AltGr reports Control and Alt together and types characters, so it is not Ctrl.
        bool ctrl = (mods & (ModifierKeys.Control | ModifierKeys.Alt)) == ModifierKeys.Control, shift = mods.HasFlag(ModifierKeys.Shift), alt = mods.HasFlag(ModifierKeys.Alt);
        bool typing = Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase;
        // With Alt held the arrows arrive as Key.System and the real key in SystemKey.
        var key = e.Key == Key.System && e.SystemKey is Key.Left or Key.Right ? e.SystemKey : e.Key;
        if (!ctrl && !alt && PresentWithKeys(key, shift))
        {
            e.Handled = true;
            return;
        }
        switch (key)
        {
            case Key.L when ctrl && !typing && _tool is null:
                Presenting = !Presenting;
                break;
            case Key.Y when ctrl && shift && !typing:
                ToggleReadAloud();
                break;
            case Key.F when ctrl:
                ShowFind();
                break;
            case Key.G when ctrl:
                ShowGoToPage();
                break;
            case Key.F3:
                if (Find.Visibility != Visibility.Visible) ShowFind();
                else if (shift) Search.Previous();
                else Search.Next();
                break;
            case Key.F7 when !typing && _tool is null:
                _ = ToggleCaret();
                break;
            case Key.F11:
                FullScreen = !FullScreen;
                break;
            case Key.Escape when LinkCard.Visibility == Visibility.Visible:
                HideLink();
                Surface.Focus();
                break;
            case Key.Escape when Find.Visibility == Visibility.Visible && !typing:
                HideFind();
                break;
            case Key.Escape when FullScreen:
                FullScreen = false;
                break;
            case Key.Escape when Speaking:
                StopSpeech();
                break;
            case Key.Escape when _reading:
                ReadingMode = false;
                break;
            case Key.Left when alt:
                GoBack();
                break;
            case Key.Right when alt:
                GoForward();
                break;
            case Key.OemPlus or Key.Add when ctrl && !typing:
                Surface.SetZoom(ZoomMath.Step(Surface.Zoom, 1));
                break;
            case Key.OemMinus or Key.Subtract when ctrl && !typing:
                Surface.SetZoom(ZoomMath.Step(Surface.Zoom, -1));
                break;
            case Key.D0 or Key.NumPad0 when ctrl && !typing:
                Surface.SetFit(FitMode.Page);
                break;
            case Key.D1 or Key.NumPad1 when ctrl && !typing:
                Surface.SetZoom(1);
                break;
            case Key.D2 or Key.NumPad2 when ctrl && !typing:
                Surface.SetFit(FitMode.Width);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    // Keys on the pages themselves.
    private void Surface_KeyDown(object sender, KeyEventArgs e)
    {
        if (PlaceWithKeys(e))
        {
            e.Handled = true;
            return;
        }
        bool ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control), shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (((shift && !_selection.IsEmpty) || _caretMode) && MoveCaret(e.Key, ctrl, shift))
        {
            e.Handled = true;
            return;
        }
        // Keys from a form field in an overlay bubble up here too.
        bool own = e.OriginalSource == Surface;
        if (own && _tool is null && e.Key == Key.Tab && !ctrl && TabToLink(shift))
        {
            e.Handled = true;
            return;
        }
        if (own && e.Key == Key.Enter && _focusLink is { } focus)
        {
            FollowLink(focus.Link);
            e.Handled = true;
            return;
        }
        bool flips = !Surface.Continuous && Surface.Layout.Extent.Width <= Surface.Viewport.Width + 1;
        switch (e.Key)
        {
            case Key.Up: Surface.ScrollBy(0, -48); break;
            case Key.Down: Surface.ScrollBy(0, 48); break;
            case Key.Left when flips: StepPage(-1); break;
            case Key.Right when flips: StepPage(1); break;
            case Key.Left: Surface.ScrollBy(-48, 0); break;
            case Key.Right: Surface.ScrollBy(48, 0); break;
            case Key.PageUp: Surface.ScrollBy(0, -Surface.Viewport.Height * 0.9); break;
            case Key.PageDown: Surface.ScrollBy(0, Surface.Viewport.Height * 0.9); break;
            case Key.Space: Surface.ScrollBy(0, (shift ? -1 : 1) * Surface.Viewport.Height * 0.9); break;
            case Key.Home: GoToPage(0); break;
            case Key.End: GoToPage(Surface.PageCount - 1); break;
            case Key.C when ctrl: _ = CopySelectionAsync(); break;
            case Key.A when ctrl: SelectAll(); break;
            case Key.Escape when _drag == Drag.Tool:
                _drag = Drag.None;
                Surface.ReleaseMouseCapture();
                _tool?.Cancel();
                break;
            case Key.Escape when _mode is PointerMode.Zoom or PointerMode.Snapshot:
                EndDrag();
                Surface.ReleaseMouseCapture();
                SetMode(_modeBeforeArea);
                break;
            case Key.Escape: ClearLinkFocus(); EscapeSelection(); break;
            default: return;
        }
        e.Handled = true;
    }
}
