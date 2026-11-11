using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Comment;

/// <summary>A small bar over the selected text with the text markups, shown while the Select text tool is in use.</summary>
internal sealed class SelectionBar
{
    private const double Gap = 6;

    private readonly IDocumentViewer _viewer;
    private readonly Func<bool> _wanted;
    private readonly DispatcherTimer _delay = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Popup _popup;
    private (int Page, TextQuad Quad)? _last;

    public SelectionBar(IDocumentViewer viewer, Func<bool> wanted, Func<AnnotationType, Task> mark)
    {
        _viewer = viewer;
        _wanted = wanted;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (kind, glyph, name) in new[] { (AnnotationType.Highlight, "", Loc.T("Highlight")), (AnnotationType.Underline, "", Loc.T("Underline")), (AnnotationType.StrikeOut, "", Loc.T("Strike out")) })
        {
            var button = new Button { Content = glyph, ToolTip = name, Margin = new Thickness(2) };
            button.SetResourceReference(FrameworkElement.StyleProperty, "SmallIconButtonStyle");
            AutomationProperties.SetName(button, name);
            button.Click += (_, _) =>
            {
                Hide();
                _ = mark(kind);
            };
            row.Children.Add(button);
        }
        var frame = new Border { Child = row, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Margin = new Thickness(8) };
        frame.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        frame.SetResourceReference(Border.BorderBrushProperty, "SurfaceStrokeColorDefaultBrush");
        frame.SetResourceReference(UIElement.EffectProperty, "CardHoverShadow");
        _popup = new Popup
        {
            Child = frame,
            AllowsTransparency = true,
            StaysOpen = true,
            Focusable = false,
            Placement = PlacementMode.Relative,
            PlacementTarget = viewer.View,
        };
        _delay.Tick += Delay_Tick;
        viewer.SelectionChanged += Viewer_SelectionChanged;
    }

    public bool IsOpen => _popup.IsOpen;

    public void Refresh()
    {
        Hide();
        if (_wanted() && _viewer.HasSelection) _delay.Start();
    }

    public void Hide()
    {
        _delay.Stop();
        _popup.IsOpen = false;
    }

    public void Dispose()
    {
        Hide();
        _viewer.SelectionChanged -= Viewer_SelectionChanged;
    }

    // Puts the bar above the last line of the selection, or below it when the line is at the top of the view.
    public void Move()
    {
        if (!_popup.IsOpen || _last is not { } last || _viewer.PageToView(last.Page) is not { } toView) return;
        var geometry = _viewer.Geometry(last.Page);
        var q = last.Quad;
        var area = Rect.Empty;
        foreach (var (x, y) in new[] { (q.X0, q.Y0), (q.X1, q.Y1), (q.X2, q.Y2), (q.X3, q.Y3) })
        {
            var (px, py) = geometry.ToDisplay(x, y);
            area.Union(toView.Transform(new Point(px, py)));
        }
        var child = (FrameworkElement)_popup.Child;
        child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = child.DesiredSize;
        double left = area.X + (area.Width - size.Width) / 2;
        double top = area.Top - size.Height - Gap;
        if (top < 0) top = area.Bottom + Gap;
        _popup.HorizontalOffset = Math.Max(left, 0);
        _popup.VerticalOffset = top;
    }

    private void Viewer_SelectionChanged(object? sender, EventArgs e) => Refresh();

    private async void Delay_Tick(object? sender, EventArgs e)
    {
        _delay.Stop();
        if (Mouse.LeftButton == MouseButtonState.Pressed)
        {
            _delay.Start();
            return;
        }
        if (!_wanted() || !_viewer.HasSelection) return;
        var runs = await _viewer.GetSelectionAsync();
        if (_delay.IsEnabled || !_wanted() || !_viewer.HasSelection || Mouse.LeftButton == MouseButtonState.Pressed) return;
        if (runs.Count == 0 || runs[^1].Quads.Count == 0) return;
        _last = (runs[^1].Page, runs[^1].Quads[^1]);
        _popup.IsOpen = true;
        Move();
    }
}
