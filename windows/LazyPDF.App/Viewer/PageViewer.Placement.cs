using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace LazyPDF.App.Viewer;

// The keyboard path for a pointer tool: Enter shows a cross in the middle of the page in view, the arrow keys move
// it (Shift for small steps, Ctrl for big ones), and Enter again is a click there. Escape lets go.
public partial class PageViewer
{
    private const double KeyStep = 8;

    private int _keyPage = -1;
    private Point _keyPoint;
    private Shape? _cross;

    private bool PlaceWithKeys(KeyEventArgs e) => PlaceWithKeys(e.Key);

    internal bool PlaceWithKeys(Key key)
    {
        if (_tool is not { } tool || _tab is null || _drag != Drag.None) return false;
        if (_keyPage < 0)
        {
            if (key != Key.Enter || CentreOfPage() is not { } centre) return false;
            _keyPage = centre.Page;
            _keyPoint = centre.Point;
            ShowCross();
            PlaceCue.Visibility = Visibility.Visible;
            (UIElementAutomationPeer.FromElement(PlaceCueText) ?? UIElementAutomationPeer.CreatePeerForElement(PlaceCueText))?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            return true;
        }
        if (Surface.PageMatrix(_keyPage) is not { } matrix)
        {
            EndKeyPlacement();
            return false;
        }
        switch (key)
        {
            case Key.Enter:
                int page = _keyPage;
                var at = _keyPoint;
                var view = Surface.TranslatePoint(matrix.Transform(at), this);
                EndKeyPlacement();
                tool.Press(new PagePointer(page, at, view, true, 1, Keyboard.Modifiers, true));
                tool.Release(new PagePointer(page, at, view, false, 0, Keyboard.Modifiers, true));
                break;
            case Key.Escape:
                EndKeyPlacement();
                break;
            case Key.Left or Key.Right or Key.Up or Key.Down:
                MoveCross(key, matrix);
                break;
            default:
                return false;
        }
        return true;
    }

    private (int Page, Point Point)? CentreOfPage()
    {
        int page = Surface.CurrentPage;
        if (Surface.PageMatrix(page) is not { } matrix) return null;
        var size = Surface.PageSize(page);
        var shown = new Rect(0, 0, size.Width, size.Height);
        shown.Transform(matrix);
        shown.Intersect(new Rect(Surface.Viewport));
        if (shown.IsEmpty) return null;
        return Surface.Hit(new Point(shown.X + shown.Width / 2, shown.Y + shown.Height / 2));
    }

    private void MoveCross(Key key, Matrix matrix)
    {
        double step = KeyStep * (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 0.125 : Keyboard.Modifiers.HasFlag(ModifierKeys.Control) ? 5 : 1);
        var shift = key switch
        {
            Key.Left => new Vector(-step, 0),
            Key.Right => new Vector(step, 0),
            Key.Up => new Vector(0, -step),
            _ => new Vector(0, step),
        };
        var moved = matrix.Transform(_keyPoint) + shift;
        matrix.Invert();
        var size = Surface.PageSize(_keyPage);
        var back = matrix.Transform(moved);
        _keyPoint = new Point(Math.Clamp(back.X, 0, size.Width), Math.Clamp(back.Y, 0, size.Height));
        ShowCross();
    }

    private void ShowCross()
    {
        var overlay = Overlay(_keyPage);
        if (_cross is null)
        {
            _cross = new System.Windows.Shapes.Path { Data = System.Windows.Media.Geometry.Parse("M-9,0 L9,0 M0,-9 L0,9"), IsHitTestVisible = false };
            _cross.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        }
        if (_cross.Parent is null) overlay.Children.Add(_cross);
        double scale = 1 / Math.Max(Surface.Zoom * PageSpace.DipPerPoint, 0.1);
        _cross.StrokeThickness = 2 * scale;
        _cross.RenderTransform = new MatrixTransform(scale, 0, 0, scale, _keyPoint.X, _keyPoint.Y);
    }

    private void EndKeyPlacement()
    {
        if (_cross?.Parent is System.Windows.Controls.Panel panel) panel.Children.Remove(_cross);
        _cross = null;
        _keyPage = -1;
        PlaceCue.Visibility = Visibility.Collapsed;
    }
}
