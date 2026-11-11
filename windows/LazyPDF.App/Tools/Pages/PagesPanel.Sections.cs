// The sections under the grid: one is open at a time, and the pinned button does what the open one sets up.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using ResizeMode = LazyPDF.Core.ResizeMode;

namespace LazyPDF.App.Tools.Pages;

public partial class PagesPanel
{
    private enum Section { None, Insert, Crop, Resize, Labels }

    private Section _section;
    private CropTool? _crop;

    public override ToolAction? Action => _section switch
    {
        Section.Crop => new(Loc.T("Crop pages"), "", () => _crop?.Box is not null, () => Run(Crop)),
        Section.Resize => new(Loc.T("Resize pages"), "", () => Size() is not null, () => Run(Resize)),
        Section.Labels => new(Loc.T("Number pages"), "", () => Start() is not null, () => Run(Number)),
        _ => null,
    };

    private Section SectionOf(object expander) =>
        ReferenceEquals(expander, InsertSection) ? Section.Insert
        : ReferenceEquals(expander, CropSection) ? Section.Crop
        : ReferenceEquals(expander, ResizeSection) ? Section.Resize
        : Section.Labels;

    private void Section_Expanded(object sender, RoutedEventArgs e)
    {
        var section = SectionOf(sender);
        Disarm();
        _section = section;
        foreach (var other in new[] { InsertSection, CropSection, ResizeSection, LabelSection })
        {
            if (!ReferenceEquals(other, sender)) other.IsExpanded = false;
        }
        Arm();
        Refresh();
    }

    private void Section_Collapsed(object sender, RoutedEventArgs e)
    {
        if (_section != SectionOf(sender)) return;
        Disarm();
        _section = Section.None;
        Refresh();
    }

    // The crop box is drawn on the pages, so the viewer's pointer belongs to the crop section while it is open and the switch is on.
    private void Arm()
    {
        if (_section != Section.Crop || Viewer is not { } viewer) return;
        _crop = new CropTool(viewer);
        _crop.BoxChanged += Crop_BoxChanged;
        viewer.ModeChanged += Viewer_ModeChanged;
        CropDraw.IsChecked = true;
    }

    private void Disarm()
    {
        if (_crop is null) return;
        _crop.BoxChanged -= Crop_BoxChanged;
        if (Viewer is { } viewer)
        {
            viewer.ModeChanged -= Viewer_ModeChanged;
            if (ReferenceEquals(viewer.PointerTool, _crop)) viewer.PointerTool = null;
        }
        _crop.Clear();
        _crop = null;
        CropDraw.IsChecked = false;
    }

    private void CropDraw_Changed(object sender, RoutedEventArgs e)
    {
        if (_crop is null || Viewer is not { } viewer) return;
        if (CropDraw.IsChecked == true) viewer.PointerTool = _crop;
        else if (ReferenceEquals(viewer.PointerTool, _crop)) viewer.PointerTool = null;
        Refresh();
    }

    // The viewer's Hand and Select buttons took the pointer; the box stays until the switch is turned on again.
    private void Viewer_ModeChanged(object? sender, EventArgs e) => CropDraw.IsChecked = false;

    private void CropAll_Click(object sender, RoutedEventArgs e) => Refresh();

    private void Crop_BoxChanged(object? sender, EventArgs e) => Refresh();

    private void RefreshHints(IReadOnlyList<int> pages)
    {
        string covered = pages.Count == 0 ? Loc.T("Every page is changed.") : Loc.Plural(pages.Count, "{0} selected page is changed.", "{0} selected pages are changed.", pages.Count);
        CropHint.Text = _crop?.Box is { } box
            ? Loc.T("Box of {0} by {1} mm.", Math.Round(box.Area.Width / PageEdits.PointsPerMillimetre), Math.Round(box.Area.Height / PageEdits.PointsPerMillimetre))
                + " " + (CropAll.IsChecked == true ? Loc.T("Every page is changed.") : pages.Count > 0 ? covered : Loc.T("Page {0} is changed.", box.Page + 1))
            : CropDraw.IsChecked == true ? Loc.T("Drag a box on a page.") : Loc.T("Turn on drawing to drag a box.");
        ResizeHint.Text = Loc.T("Pages keep their orientation.") + " " + covered;
        LabelHint.Text = pages.Count == 0 ? Loc.T("Every page is numbered.") : Loc.T("Pages {0} to {1} are numbered.", pages[0] + 1, pages[^1] + 1);
        CustomSize.Visibility = Paper.SelectedIndex == PaperSize.All.Count ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Paper_SelectionChanged(object sender, SelectionChangedEventArgs e) => Refresh();

    private static Task Run(Action work)
    {
        work();
        return Task.CompletedTask;
    }

    private void Crop()
    {
        if (_crop?.Box is not { } box) return;
        var pages = CropAll.IsChecked == true ? [.. Enumerable.Range(0, Cells.Count)] : Selected().Count > 0 ? Selected() : [box.Page];
        var targets = PageEdits.CropTargets(Tab!.Document, pages, box.Area);
        if (targets.Count == 0)
        {
            Host!.ShowProblem(new Problem(Loc.T("Box is off the pages"), Loc.T("The box does not touch the pages to crop. Draw it again on a page.")));
            return;
        }
        int left = pages.Count - targets.Count;
        string status = Loc.Plural(targets.Count, "{0} page cropped", "{0} pages cropped", targets.Count);
        if (left > 0) status += " " + Loc.Plural(left, "{0} page was left alone because the box is outside it.", "{0} pages were left alone because the box is outside them.", left);
        if (Apply(Loc.T("Crop pages"), d => PageEdits.Crop(d, targets, box.Area), Selected(), status)) _crop.Clear();
    }

    private void CropReset_Click(object sender, RoutedEventArgs e)
    {
        var pages = SelectedOrAll();
        Apply(Loc.T("Remove crop"), d => PageOperations.SetBox(d, pages, PageBox.Crop, null), Selected(), Loc.T("Crop removed."));
    }

    // The chosen paper in points; null while the custom size is not a number within what a page can be.
    private (double Width, double Height)? Size()
    {
        if (Paper.SelectedIndex < 0) return null;
        if (Paper.SelectedIndex < PaperSize.All.Count) return (PaperSize.All[Paper.SelectedIndex].Width, PaperSize.All[Paper.SelectedIndex].Height);
        if (!double.TryParse(CustomWidth.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double width)
            || !double.TryParse(CustomHeight.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double height)) return null;
        width *= PageEdits.PointsPerMillimetre;
        height *= PageEdits.PointsPerMillimetre;
        return width is >= 10 and <= 14400 && height is >= 10 and <= 14400 ? (width, height) : null;
    }

    private void Resize()
    {
        if (Size() is not { } size) return;
        var pages = SelectedOrAll();
        var mode = ScaleContent.IsChecked == true ? ResizeMode.ScaleContent : ResizeMode.ChangeBox;
        Apply(Loc.T("Resize pages"), d => PageEdits.ResizeTo(d, pages, size.Width, size.Height, mode), Selected(), Loc.Plural(pages.Count, "{0} page resized", "{0} pages resized", pages.Count));
    }

    private int? Start() => int.TryParse(LabelStart.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int start) && start >= 1 ? start : null;

    private void Number()
    {
        if (Start() is not { } start) return;
        var (first, last) = PageEdits.Span(SelectedOrAll());
        var style = LabelStyle.SelectedIndex switch
        {
            1 => PageLabelStyle.LowerRoman,
            2 => PageLabelStyle.UpperRoman,
            3 => PageLabelStyle.LowerLetters,
            4 => PageLabelStyle.UpperLetters,
            5 => PageLabelStyle.None,
            _ => PageLabelStyle.Decimal,
        };
        string prefix = LabelPrefix.Text;
        Apply(Loc.T("Number pages"), d => PageEdits.Relabel(d, first, last, style, prefix, start), Selected(), Loc.T("Pages numbered."));
    }

    private void LabelClear_Click(object sender, RoutedEventArgs e) =>
        Apply(Loc.T("Remove page labels"), PageEdits.ClearLabels, Selected(), Loc.T("Labels removed."));
}
