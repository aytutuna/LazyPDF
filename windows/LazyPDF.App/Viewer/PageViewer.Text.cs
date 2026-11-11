using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Tools.Export;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// Text: reading it for a revision, selecting it, copying it, and drawing the selection and the search hits.
public partial class PageViewer
{
    private static readonly Brush HitBrush = Frozen(Color.FromArgb(110, 255, 214, 0));
    private static readonly Brush CurrentHitBrush = Frozen(Color.FromArgb(160, 255, 140, 0));

    private readonly ViewerSelection _selection = new();
    private PagePoint? _anchorWaiting;
    private int _press;
    private bool _unitWaiting;
    private (Caret Start, Caret End, int Clicks)? _multi;
    private Brush? _selectionBrush;
    private Color _selectionColor;
    private readonly Dictionary<int, System.Windows.Media.Geometry?> _selectionGeometry = [];
    private readonly Dictionary<int, (System.Windows.Media.Geometry? Others, System.Windows.Media.Geometry? Current)> _hitGeometry = [];
    private readonly DispatcherTimer _preload = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private Task<TextSource?>? _text;
    private TextSource? _source;
    private bool _caretMode;

    public event EventHandler? SelectionChanged;

    public bool HasSelection => !_selection.IsEmpty;

    // Taken when drawn, so an accent change during the session and the high contrast highlight show.
    private Brush SelectionFill()
    {
        var color = SystemParameters.HighContrast ? SystemColors.HighlightColor : SystemColors.AccentColor;
        if (_selectionBrush is null || color != _selectionColor)
        {
            _selectionColor = color;
            _selectionBrush = Frozen(Color.FromArgb(SystemParameters.HighContrast ? (byte)140 : (byte)90, color.R, color.G, color.B));
        }
        return _selectionBrush;
    }

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private void InitText()
    {
        _selection.Changed += (_, _) =>
        {
            _selectionGeometry.Clear();
            Surface.InvalidateVisual();
            SelectionChanged?.Invoke(this, EventArgs.Empty);
        };
        _preload.Tick += (_, _) =>
        {
            _preload.Stop();
            foreach (int page in VisiblePages.Take(8)) _ = LoadPageAsync(page);
        };
    }

    // The file changed or another one is shown: what was read is stale.
    private void ResetText()
    {
        _text = null;
        _source = null;
        _links.Clear();
        _focusLink = null;
        _selectionGeometry.Clear();
        _hitGeometry.Clear();
        CancelPendingSelection();
        _selection.Clear();
        _caretMode = false;
    }

    private Task<TextSource?> TextAsync()
    {
        if (_tab is not { } tab) return Task.FromResult<TextSource?>(null);
        if (_text is { } open) return open;
        var task = TextSource.OpenAsync(PageSurface.Bytes(tab), tab.Password, tab.Certificate);
        _text = task;
        _ = task.ContinueWith(done =>
        {
            if (!ReferenceEquals(_text, task)) return;
            _source = done.Result;
            Surface.InvalidateVisual();
        }, TaskScheduler.FromCurrentSynchronizationContext());
        return task;
    }

    private void PreloadText()
    {
        _preload.Stop();
        _preload.Start();
    }

    private async Task LoadPageAsync(int page)
    {
        if (await GetTextAsync(page) is not null) Surface.InvalidateVisual();
    }

    public async Task<TextPage?> GetTextAsync(int page) =>
        await TextAsync() is { } source ? await source.GetAsync(page) : null;

    private TextPage? LoadedText(int page) => _source?.Peek(page);

    private bool IsOverText(int page, Point point)
    {
        if (LoadedText(page) is not { } text)
        {
            return false;
        }
        var (x, y) = Surface.Geometry(page).ToUser(point.X, point.Y);
        return text.HitTest(x, y, 2) is not null;
    }

    // ----- Selecting

    private void BeginSelection(Point at, int clicks)
    {
        int press = ++_press;
        _anchorWaiting = null;
        _unitWaiting = false;
        _multi = null;
        if (Surface.Hit(at, nearest: true) is not { } hit) return;
        _dragPage = hit.Page;
        bool extend = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) && !_selection.IsEmpty;
        if (LoadedText(hit.Page) is not { } text)
        {
            if (clicks >= 2)
            {
                _unitWaiting = true;
                _ = SelectUnitWhenLoadedAsync(hit, clicks, press);
                return;
            }
            _ = LoadPageAsync(hit.Page);
            if (!extend)
            {
                _selection.Clear();
                _anchorWaiting = new PagePoint(hit.Page, hit.Point);
            }
            return;
        }
        if (clicks >= 2)
        {
            SelectUnit(hit, text, clicks);
            return;
        }
        var (x, y) = Surface.Geometry(hit.Page).ToUser(hit.Point.X, hit.Point.Y);
        var caret = new Caret(hit.Page, text.CaretAt(x, y));
        if (extend) _selection.Extend(caret);
        else _selection.Set(caret, caret);
    }

    private async Task SelectUnitWhenLoadedAsync((int Page, Point Point) hit, int clicks, int press)
    {
        var tab = _tab;
        try
        {
            await LoadPageAsync(hit.Page);
            if (press != _press || !ReferenceEquals(tab, _tab) || LoadedText(hit.Page) is not { } text) return;
            SelectUnit(hit, text, clicks);
        }
        finally
        {
            _unitWaiting = false;
        }
    }

    // A double or triple click still waiting for its page text must not select after a later action.
    private void CancelPendingSelection() => _press++;

    private void SelectUnit((int Page, Point Point) hit, TextPage text, int clicks)
    {
        var (x, y) = Surface.Geometry(hit.Page).ToUser(hit.Point.X, hit.Point.Y);
        var chosen = clicks == 2 ? TextSelection.WordAt(text, x, y) : TextSelection.LineAt(text, x, y);
        if (chosen.IsEmpty)
        {
            _selection.Clear();
            return;
        }
        var (first, last) = (new Caret(hit.Page, chosen.Ranges[0].Start), new Caret(hit.Page, chosen.Ranges[^1].End));
        _selection.Set(first, last);
        _multi = (first, last, clicks);
    }

    private void DragSelection(Point at)
    {
        if (_unitWaiting || !_moved || Surface.Hit(at, nearest: true) is not { } hit) return;
        if (LoadedText(hit.Page) is not { } text)
        {
            _ = LoadPageAsync(hit.Page);
            return;
        }
        if (_anchorWaiting is { } waiting)
        {
            // The press came before the page's text did; the selection starts where the press was.
            if (LoadedText(waiting.Page) is not { } anchorText)
            {
                _ = LoadPageAsync(waiting.Page);
                return;
            }
            var (ax, ay) = Surface.Geometry(waiting.Page).ToUser(waiting.Point.X, waiting.Point.Y);
            var anchor = new Caret(waiting.Page, anchorText.CaretAt(ax, ay));
            _selection.Set(anchor, anchor);
            _anchorWaiting = null;
        }
        var (x, y) = Surface.Geometry(hit.Page).ToUser(hit.Point.X, hit.Point.Y);
        if (_multi is { } multi)
        {
            // After a double or triple click the selection grows by whole words or lines.
            var unit = multi.Clicks == 2 ? TextSelection.WordAt(text, x, y) : TextSelection.LineAt(text, x, y);
            if (unit.IsEmpty) return;
            var (from, to) = (new Caret(hit.Page, unit.Ranges[0].Start), new Caret(hit.Page, unit.Ranges[^1].End));
            if (from < multi.Start) _selection.Set(multi.End, from);
            else _selection.Set(multi.Start, to);
            return;
        }
        _selection.Extend(new Caret(hit.Page, text.CaretAt(x, y)));
    }

    public void SelectAll()
    {
        if (_tab is null) return;
        CancelPendingSelection();
        _selection.SelectAll(Surface.PageCount);
        foreach (int page in VisiblePages) _ = LoadPageAsync(page);
    }

    public void ClearSelection()
    {
        CancelPendingSelection();
        _selection.Clear();
    }

    // F7: the caret can be moved, and a selection started, with the arrow keys.
    internal async Task ToggleCaret()
    {
        if (_tab is null) return;
        if (_caretMode)
        {
            _caretMode = false;
            Surface.InvalidateVisual();
            ShowToast(Loc.T("Caret browsing is off."));
            return;
        }
        if (_selection.IsEmpty)
        {
            var tab = _tab;
            if (Surface.Hit(new Point(24, 24), nearest: true) is not { } hit) return;
            await LoadPageAsync(hit.Page);
            if (!ReferenceEquals(tab, _tab) || LoadedText(hit.Page) is not { } text) return;
            if (text.Chars.Count == 0)
            {
                ShowToast(Loc.T("This page has no text to move through."));
                return;
            }
            var (x, y) = Surface.Geometry(hit.Page).ToUser(hit.Point.X, hit.Point.Y);
            var caret = new Caret(hit.Page, text.CaretAt(x, y));
            _selection.Set(caret, caret);
        }
        _caretMode = true;
        Surface.InvalidateVisual();
        ShowToast(Loc.T("Caret browsing is on. Arrow keys move the caret and Shift selects. F7 turns it off."));
    }

    // Moves the focus end of the selection as a text caret would. False for a key that is not one of its.
    internal bool MoveCaret(Key key, bool ctrl, bool extend)
    {
        if (key is not (Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End)) return false;
        var focus = _selection.Focus;
        if (LoadedText(focus.Page) is not { } text)
        {
            _ = LoadPageAsync(focus.Page);
            return false;
        }
        int count = text.Chars.Count;
        int index = Math.Min(focus.Index, count);
        Caret? next = key switch
        {
            Key.Left when ctrl => index > 0 ? new Caret(focus.Page, PreviousWord(text, index)) : focus.Page > 0 ? new Caret(focus.Page - 1, int.MaxValue) : null,
            Key.Right when ctrl => index < count ? new Caret(focus.Page, NextWord(text, index)) : focus.Page < Surface.PageCount - 1 ? new Caret(focus.Page + 1, 0) : null,
            Key.Left => index > 0 ? new Caret(focus.Page, index - 1) : focus.Page > 0 ? new Caret(focus.Page - 1, int.MaxValue) : null,
            Key.Right => index < count ? new Caret(focus.Page, index + 1) : focus.Page < Surface.PageCount - 1 ? new Caret(focus.Page + 1, 0) : null,
            Key.Up => MoveLine(focus.Page, text, index, -1),
            Key.Down => MoveLine(focus.Page, text, index, 1),
            Key.Home when ctrl => new Caret(0, 0),
            Key.End when ctrl => new Caret(Surface.PageCount - 1, int.MaxValue),
            Key.Home => new Caret(focus.Page, LineEdge(text, index, start: true)),
            Key.End => new Caret(focus.Page, LineEdge(text, index, start: false)),
            _ => null,
        };
        if (next is { } caret)
        {
            CancelPendingSelection();
            if (extend) _selection.Extend(caret);
            else _selection.Set(caret, caret);
            RevealCaret(caret);
            if (caret.Page == focus.Page) Speak(Moved(text, key, index, Math.Min(caret.Index, count)));
        }
        return true;
    }

    // What the caret went over: the character, the word, or the line it is on now.
    private static string Moved(TextPage text, Key key, int from, int to)
    {
        if (key is Key.Left or Key.Right) return text.GetText(new TextRange(Math.Min(from, to), Math.Max(from, to))).Trim();
        if (text.Chars.Count == 0) return "";
        return text.Lines[LineOf(text, to == text.Chars.Count ? to - 1 : to)].Text;
    }

    private static int NextWord(TextPage text, int index) =>
        text.Words.FirstOrDefault(w => w.Range.Start > index)?.Range.Start ?? text.Chars.Count;

    private static int PreviousWord(TextPage text, int index) =>
        text.Words.LastOrDefault(w => w.Range.Start < index)?.Range.Start ?? 0;

    private static int LineOf(TextPage text, int index) => text.Chars[Math.Clamp(index, 0, text.Chars.Count - 1)].Line;

    private static int LineEdge(TextPage text, int index, bool start)
    {
        if (text.Chars.Count == 0) return 0;
        var range = text.Lines[LineOf(text, index == text.Chars.Count ? index - 1 : index)].Range;
        return start ? range.Start : range.End;
    }

    private static Caret? MoveLine(int page, TextPage text, int index, int step)
    {
        if (text.Chars.Count == 0) return null;
        int line = LineOf(text, index == text.Chars.Count ? index - 1 : index) + step;
        if (line < 0) return new Caret(page, 0);
        if (line >= text.Lines.Count) return new Caret(page, text.Chars.Count);
        var (x, _) = text.Chars[Math.Min(index, text.Chars.Count - 1)].Quad.Center;
        var (_, y) = text.Lines[line].Quad.Center;
        return new Caret(page, text.CaretAt(x, y));
    }

    // The rectangle of page space that holds the quads (user space).
    private Rect PageBounds(int page, IEnumerable<TextQuad> quads)
    {
        var geometry = Surface.Geometry(page);
        var area = Rect.Empty;
        foreach (var quad in quads)
        {
            var box = quad.Bounds;
            var (x1, y1) = geometry.ToDisplay(box.Left, box.Bottom);
            var (x2, y2) = geometry.ToDisplay(box.Right, box.Top);
            area.Union(new Rect(new Point(x1, y1), new Point(x2, y2)));
        }
        return area;
    }

    // Scrolls to the character the caret is at, if it is out of view.
    private void RevealCaret(Caret caret)
    {
        if (LoadedText(caret.Page) is not { } text || text.Chars.Count == 0) return;
        int i = Math.Clamp(caret.Index, 0, text.Chars.Count - 1);
        var area = PageBounds(caret.Page, text.Quads(new TextRange(i, i + 1)));
        if (!area.IsEmpty) Surface.Reveal(caret.Page, area);
    }

    public async Task<IReadOnlyList<SelectedRun>> GetSelectionAsync()
    {
        var runs = new List<SelectedRun>();
        if (_selection.IsEmpty) return runs;
        var (first, last) = (_selection.Start.Page, _selection.End.Page);
        for (int page = first; page <= last; page++)
        {
            if (await GetTextAsync(page) is not { } text) continue;
            if (_selection.On(page, text.Chars.Count) is not { } range) continue;
            runs.Add(new SelectedRun(page, range, text.GetText(range), text.Quads(range)));
        }
        return runs;
    }

    private string? SelectedOnOnePage()
    {
        int page = _selection.Start.Page;
        if (LoadedText(page) is not { } text || _selection.On(page, text.Chars.Count) is not { } range) return null;
        return text.GetText(range);
    }

    public bool CanCopy => _tab is null || Exporter.Allowed(_tab.Document);

    private bool RefuseCopy()
    {
        if (CanCopy) return false;
        Tell(Loc.T("The owner of this file does not allow copying."), null);
        return true;
    }

    internal async Task CopySelectionAsync()
    {
        if (_selection.IsEmpty || RefuseCopy()) return;
        var runs = await GetSelectionAsync();
        if (runs.Count == 0) return;
        string text = string.Join("\n", runs.Select(r => r.Text));
        // Another program may hold the clipboard for a moment.
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Clipboard.SetText(text);
                return;
            }
            catch (ExternalException)
            {
                await Task.Delay(50);
            }
        }
    }

    // ----- Drawing on the pages

    private void Decorate(DrawingContext dc, int page, Matrix matrix)
    {
        bool hasHits = Search.Hits.Count > 0;
        bool selected = _selection.Covers(page);
        bool caret = _caretMode && _selection.Focus.Page == page;
        bool ringed = _focusLink is { } ring && ring.Page == page;
        if (!hasHits && !selected && !caret && !ringed) return;
        dc.PushTransform(new MatrixTransform(matrix));
        if (hasHits)
        {
            if (!_hitGeometry.TryGetValue(page, out var hits)) _hitGeometry[page] = hits = HitGeometry(page);
            if (hits.Others is not null) dc.DrawGeometry(HitBrush, null, hits.Others);
            if (hits.Current is not null) dc.DrawGeometry(CurrentHitBrush, null, hits.Current);
        }
        if (selected && LoadedText(page) is { } text)
        {
            if (!_selectionGeometry.TryGetValue(page, out var shape))
            {
                _selectionGeometry[page] = shape = _selection.On(page, text.Chars.Count) is { } range ? Outline(page, text.Quads(range)) : null;
            }
            if (shape is not null) dc.DrawGeometry(SelectionFill(), null, shape);
        }
        else if (selected)
        {
            _ = LoadPageAsync(page);
        }
        if (caret && LoadedText(page) is { } caretText) DrawCaret(dc, page, caretText, matrix.M11 * VisualTreeHelper.GetDpi(Surface).DpiScaleX);
        if (ringed) DrawLinkRing(dc, page, matrix.M11 * VisualTreeHelper.GetDpi(Surface).DpiScaleX);
        dc.Pop();
    }

    private void DrawLinkRing(DrawingContext dc, int page, double pixelsPerUnit)
    {
        var area = Surface.Geometry(page).ToDisplay(_focusLink!.Value.Link.Rect);
        var ring = new Rect(area.X - 2, area.Y - 2, area.Width + 4, area.Height + 4);
        dc.DrawRectangle(null, new Pen(Brushes.White, 3 / pixelsPerUnit), ring);
        dc.DrawRectangle(null, new Pen(Brushes.Black, 1.5 / pixelsPerUnit), ring);
    }

    private void DrawCaret(DrawingContext dc, int page, TextPage text, double pixelsPerUnit)
    {
        int count = text.Chars.Count;
        if (count == 0) return;
        int index = Math.Min(_selection.Focus.Index, count);
        bool atEnd = index == count;
        var area = PageBounds(page, text.Quads(new TextRange(atEnd ? index - 1 : index, atEnd ? index : index + 1)));
        if (area.IsEmpty) return;
        double width = 1.5 / pixelsPerUnit;
        var brush = Surface.Tint == PageTint.Dark ? Brushes.White : Brushes.Black;
        dc.DrawRectangle(brush, null, new Rect(atEnd ? area.Right : area.Left, area.Top, width, area.Height));
    }

    private (System.Windows.Media.Geometry? Others, System.Windows.Media.Geometry? Current) HitGeometry(int page)
    {
        var others = new List<TextQuad>();
        var current = new List<TextQuad>();
        for (int i = 0; i < Search.Hits.Count; i++)
        {
            var hit = Search.Hits[i];
            if (hit.Page == page) (i == Search.Current ? current : others).AddRange(hit.Match.Quads);
        }
        return (others.Count > 0 ? Outline(page, others) : null, current.Count > 0 ? Outline(page, current) : null);
    }

    // The quads (user space) as one shape in page space.
    private System.Windows.Media.Geometry Outline(int page, IEnumerable<TextQuad> quads)
    {
        var geometry = Surface.Geometry(page);
        var shape = new StreamGeometry();
        using (var context = shape.Open())
        {
            foreach (var q in quads)
            {
                var (ax, ay) = geometry.ToDisplay(q.X0, q.Y0);
                var (bx, by) = geometry.ToDisplay(q.X1, q.Y1);
                var (cx, cy) = geometry.ToDisplay(q.X2, q.Y2);
                var (dx, dy) = geometry.ToDisplay(q.X3, q.Y3);
                context.BeginFigure(new Point(ax, ay), true, true);
                context.LineTo(new Point(bx, by), false, false);
                context.LineTo(new Point(cx, cy), false, false);
                context.LineTo(new Point(dx, dy), false, false);
            }
        }
        shape.Freeze();
        return shape;
    }
}
