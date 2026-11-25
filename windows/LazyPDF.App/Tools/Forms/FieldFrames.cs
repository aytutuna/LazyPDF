using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

/// <summary>The outlines of the fields on the pages in view while they are being edited, the selected ones, with handles when there is one, and the fields the detector found.</summary>
internal sealed class FieldFrames(IDocumentViewer viewer)
{
    private const double HandleSize = 8;

    private readonly Dictionary<int, Canvas> _hosts = [];
    private PdfForm? _form;
    private HashSet<(string Name, int Index, int Ordinal)> _picked = [];
    private IReadOnlyList<FieldProposal> _proposals = [];
    private string _seen = "";

    /// <summary>Pixels in one point of the page at the present zoom.</summary>
    public static double Scale(IDocumentViewer viewer) => Math.Max(viewer.Zoom, 0.05) * PageSpace.DipPerPoint;

    /// <summary>The centres of the eight handles of a box, clockwise from the top left corner.</summary>
    public static Point[] Handles(Rect box)
    {
        double cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
        return [box.TopLeft, new(cx, box.Top), box.TopRight, new(box.Right, cy), box.BottomRight, new(cx, box.Bottom), box.BottomLeft, new(box.Left, cy)];
    }

    public void Show(PdfForm form, IEnumerable<(string Name, int Index, int Ordinal)> picked, IReadOnlyList<FieldProposal> proposals)
    {
        _form = form;
        _picked = [.. picked];
        _proposals = proposals;
        Redraw();
    }

    /// <summary>Draws again when other pages came into view or the zoom changed.</summary>
    public void Follow()
    {
        if (_form is not null && Seen() != _seen) Redraw();
    }

    public void Clear()
    {
        foreach (var (page, host) in _hosts) viewer.Overlay(page).Children.Remove(host);
        _hosts.Clear();
        _form = null;
    }

    private string Seen() => string.Join(',', viewer.VisiblePages) + "@" + viewer.Zoom;

    private void Redraw()
    {
        foreach (var (page, host) in _hosts) viewer.Overlay(page).Children.Remove(host);
        _hosts.Clear();
        _seen = Seen();
        double scale = Scale(viewer);
        var seen = new Dictionary<string, int>();
        var widgets = _form!.Fields.SelectMany(f =>
        {
            int ordinal = seen.GetValueOrDefault(f.Name);
            seen[f.Name] = ordinal + 1;
            return f.Widgets.Select((w, i) => (Widget: w, Field: f, Index: i, Ordinal: ordinal));
        }).ToLookup(t => t.Widget.PageIndex);
        foreach (int page in viewer.VisiblePages)
        {
            var host = new Canvas { IsHitTestVisible = false };
            var geometry = viewer.Geometry(page);
            foreach (var (widget, field, index, ordinal) in widgets[page])
            {
                var d = geometry.ToDisplay(widget.Rect);
                bool selected = _picked.Contains((field.Name, index, ordinal));
                var box = new Rect(d.X, d.Y, d.Width, d.Height);
                host.Children.Add(Outline(box, selected ? 2.5 : 1.25, scale, filled: selected, dashed: false));
                if (!selected || _picked.Count > 1) continue;
                foreach (var centre in Handles(box)) host.Children.Add(Handle(centre, scale));
            }
            foreach (var proposal in _proposals.Where(p => p.PageIndex == page))
            {
                var d = geometry.ToDisplay(proposal.Rect);
                host.Children.Add(Outline(new Rect(d.X, d.Y, d.Width, d.Height), 1.5, scale, filled: true, dashed: true));
            }
            _hosts[page] = host;
            viewer.Overlay(page).Children.Add(host);
        }
    }

    private static Rectangle Outline(Rect box, double width, double scale, bool filled, bool dashed)
    {
        var outline = new Rectangle { Width = box.Width, Height = box.Height, StrokeThickness = width / scale };
        outline.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        if (filled) outline.SetResourceReference(Shape.FillProperty, "MarqueeFillBrush");
        if (dashed) outline.StrokeDashArray = [4, 3];
        Canvas.SetLeft(outline, box.X);
        Canvas.SetTop(outline, box.Y);
        return outline;
    }

    private static Rectangle Handle(Point centre, double scale)
    {
        double size = HandleSize / scale;
        var handle = new Rectangle { Width = size, Height = size, Fill = Brushes.White, StrokeThickness = 1.5 / scale };
        handle.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        Canvas.SetLeft(handle, centre.X - size / 2);
        Canvas.SetTop(handle, centre.Y - size / 2);
        return handle;
    }
}
