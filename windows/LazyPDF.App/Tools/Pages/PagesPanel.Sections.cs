// The sections under the grid: one is open at a time, and the pinned button does what the open one sets up.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Export;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;
using ResizeMode = LazyPDF.Core.ResizeMode;

namespace LazyPDF.App.Tools.Pages;

public partial class PagesPanel
{
    private enum Section { None, Insert, Crop, Resize, Labels, Blank }

    private Section _section;
    private CropTool? _crop;

    public override ToolAction? Action => _section switch
    {
        Section.Crop => new(Loc.T("Crop pages"), "", () => _crop?.Box is not null, () => Run(Crop)),
        Section.Resize => new(Loc.T("Resize pages"), "", () => Size() is not null, () => Run(Resize)),
        Section.Labels => new(Loc.T("Number pages"), "", () => Start() is not null, () => Run(Number)),
        Section.Blank => new(Loc.T("Delete checked pages"), "", () => BlankList.Items.Cast<CheckBox>().Any(c => c.IsChecked == true), () => Run(DeleteBlank)),
        _ => null,
    };

    private Section SectionOf(object expander) =>
        ReferenceEquals(expander, InsertSection) ? Section.Insert
        : ReferenceEquals(expander, CropSection) ? Section.Crop
        : ReferenceEquals(expander, ResizeSection) ? Section.Resize
        : ReferenceEquals(expander, BlankSection) ? Section.Blank
        : Section.Labels;

    private void Section_Expanded(object sender, RoutedEventArgs e)
    {
        var section = SectionOf(sender);
        Disarm();
        _section = section;
        foreach (var other in new[] { InsertSection, CropSection, ResizeSection, LabelSection, BlankSection })
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
        ClearBlank();
        if (_crop is null) return;
        _crop.BoxChanged -= Crop_BoxChanged;
        if (Viewer is { } viewer)
        {
            viewer.ModeChanged -= Viewer_ModeChanged;
            if (ReferenceEquals(viewer.PointerTool, _crop)) viewer.PointerTool = null;
        }
        _crop.Clear();
        _crop = null;
        if (_boxSelected) DeselectBoxPage();
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

    private void CropAll_Click(object sender, RoutedEventArgs e)
    {
        SelectBoxPage();
        Refresh();
    }

    private void Crop_BoxChanged(object? sender, EventArgs e)
    {
        if (_crop?.Box is { } box) _boxSpace = BoxSpace(box.Page);
        else if (_boxSelected) DeselectBoxPage();
        SelectBoxPage();
        Refresh();
    }

    // Drawing never changes a choice the person made; only an empty selection gets the box's page, and that goes with the box.
    private void SelectBoxPage()
    {
        if (_crop?.Box is not { } box || CropAll.IsChecked == true || Cells.Count <= box.Page || Selected().Count > 0) return;
        _syncing = true;
        Thumbs.SelectedItems.Add(Cells[box.Page]);
        _syncing = false;
        _boxSelected = true;
        Thumbs.ScrollIntoView(Cells[box.Page]);
    }

    private void DeselectBoxPage()
    {
        _boxSelected = false;
        _syncing = true;
        Thumbs.SelectedItems.Clear();
        _syncing = false;
    }

    private void RefreshHints(IReadOnlyList<int> pages)
    {
        string covered = pages.Count == 0 ? Loc.T("Every page is changed.") : Loc.Plural(pages.Count, "{0} selected page is changed.", "{0} selected pages are changed.", pages.Count);
        CropHint.Text = _crop?.Box is { } box
            ? Loc.T("Box of {0} by {1} mm.", Math.Round(box.Area.Width / PageEdits.PointsPerMillimetre), Math.Round(box.Area.Height / PageEdits.PointsPerMillimetre))
                + " " + (CropAll.IsChecked == true ? Loc.T("Every page is changed.") : pages.Count > 0 ? covered : Loc.T("Page {0} is changed.", box.Page + 1))
            : CropDraw.IsChecked == true ? Loc.T("Drag a box on a page.") : Loc.T("Turn on drawing to drag a box.");
        CropHint.Text += " " + Loc.T("The rest of the page stays in the file, only hidden. Redact removes it for good.");
        CropMargins.IsEnabled = Margins() is not null;
        if (!CropMargins.IsEnabled) CropHint.Text += " " + Loc.T("Type margins as numbers, 0 or more.");
        else
        {
            int marked = MarginPages().Count;
            CropHint.Text += " " + (marked < Cells.Count
                ? Loc.Plural(marked, "The margins change {0} selected page.", "The margins change {0} selected pages.", marked)
                : Loc.T("The margins change every page."));
        }
        TrimWhite.IsEnabled = Tab!.CanDraw;
        TrimHint.Text = Tab.CanDraw
            ? Loc.T("Crops each page to what is printed on it, plus a small border. The rest stays in the file, only hidden.")
            : Loc.T("Windows cannot draw this file.");
        ResizeHint.Text = Loc.T("Pages keep their orientation.") + " " + covered;
        if (!Tab.CanDraw) BlankHint.Text = Loc.T("Windows cannot draw this file.");
        FindBlank.IsEnabled = Tab.CanDraw;
        LabelHint.Text = pages.Count == 0 ? Loc.T("Every page is numbered.") : Loc.T("Pages {0} to {1} are numbered.", pages[0] + 1, pages[^1] + 1);
        LabelHint.Text += " " + Loc.T("This sets the page numbers viewers show. Nothing is printed on the pages.");
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
        // The box outlives edits that remove its page.
        pages = [.. pages.Where(p => p < Tab!.Document.Pages.Count)];
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

    private static string MarginUnit => RegionInfo.CurrentRegion.IsMetric ? "mm" : "in";

    private void NameMarginFields()
    {
        CropLeftLabel.Text = Loc.T("Left ({0})", MarginUnit);
        CropRightLabel.Text = Loc.T("Right ({0})", MarginUnit);
        CropTopLabel.Text = Loc.T("Top ({0})", MarginUnit);
        CropBottomLabel.Text = Loc.T("Bottom ({0})", MarginUnit);
        foreach (var (box, label) in new[] { (CropLeft, CropLeftLabel), (CropRight, CropRightLabel), (CropTop, CropTopLabel), (CropBottom, CropBottomLabel) })
            System.Windows.Automation.AutomationProperties.SetName(box, label.Text);
    }

    // The typed margins in points, in the units of the system; null while one is not a number of 0 or more. Empty counts as 0.
    private (double Left, double Top, double Right, double Bottom)? Margins()
    {
        double perUnit = RegionInfo.CurrentRegion.IsMetric ? PageEdits.PointsPerMillimetre : 72;
        double[] values = new double[4];
        var boxes = new[] { CropLeft, CropTop, CropRight, CropBottom };
        for (int i = 0; i < boxes.Length; i++)
        {
            string text = boxes[i].Text.Trim();
            if (text.Length == 0) continue;
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out double value) || !(value >= 0) || double.IsInfinity(value)) return null;
            values[i] = value * perUnit;
        }
        return (values[0], values[1], values[2], values[3]);
    }

    // A page picked only to hold the drawn box is not a choice of the person, so the margins leave it out.
    private List<int> MarginPages() => CropAll.IsChecked != true && !_boxSelected ? SelectedOrAll() : [.. Enumerable.Range(0, Cells.Count)];

    private void CropMargins_Click(object sender, RoutedEventArgs e)
    {
        if (Margins() is not { } m) return;
        var pages = MarginPages();
        var targets = PageEdits.CropMarginTargets(Tab!.Document, pages, m.Left, m.Top, m.Right, m.Bottom);
        if (targets.Count == 0)
        {
            Host!.ShowProblem(new Problem(Loc.T("Margins too large"), Loc.T("The margins leave nothing of the page. Type smaller numbers.")));
            return;
        }
        int left = pages.Count - targets.Count;
        string status = Loc.Plural(targets.Count, "{0} page cropped", "{0} pages cropped", targets.Count);
        if (left > 0) status += " " + Loc.Plural(left, "{0} page was left alone because the box is outside it.", "{0} pages were left alone because the box is outside them.", left);
        Apply(Loc.T("Crop pages"), d => PageEdits.CropMargins(d, targets, m.Left, m.Top, m.Right, m.Bottom), Selected(), status);
    }

    private async void TrimWhite_Click(object sender, RoutedEventArgs e) => await TrimMargins();

    private async Task TrimMargins()
    {
        if (Tab is not { CanDraw: true } tab || Host is not { } host) return;
        var pages = SelectedOrAll();
        var sizes = pages.Select(p => new PageGeometry(tab.Document.Pages[p])).Select(g => (g.Width, g.Height)).ToList();
        int revision = tab.Revision;
        var source = Exporter.Source(tab, new WicImageCodec());
        var boxes = new Dictionary<int, DisplayRect>();
        bool scanned = false;
        await host.RunBusyAsync(Loc.T("Looking at the pages"), token => Task.Run(() =>
        {
            using var drawn = Exporter.Snapshot(source);
            if (drawn is null) return;
            for (int i = 0; i < pages.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                int done = i + 1;
                if (i % 10 == 0) Dispatcher.BeginInvoke(() => host.SetBusyText(Loc.T("Looking at page {0} of {1}", done, pages.Count)));
                if (drawn.Render(pages[i], PageEdits.TrimDpi) is { } image && PageEdits.TrimBox(image, sizes[i].Width, sizes[i].Height) is { } area)
                    boxes[pages[i]] = area;
            }
            scanned = true;
        }, token));
        if (!scanned) return;
        if (!ReferenceEquals(Tab, tab) || tab.Revision != revision)
        {
            host.ShowNotice(Loc.T("Trim margins"), Loc.T("The file changed. Nothing was trimmed."));
            return;
        }
        int left = pages.Count - boxes.Count;
        string untouched = Loc.Plural(left, "{0} page had nothing to trim and was left alone.", "{0} pages had nothing to trim and were left alone.", left);
        if (boxes.Count == 0)
        {
            host.ShowNotice(Loc.T("Trim margins"), untouched);
            return;
        }
        string status = Loc.Plural(boxes.Count, "{0} page trimmed", "{0} pages trimmed", boxes.Count);
        if (left > 0) status += " " + untouched;
        Apply(Loc.T("Trim margins"), d => PageEdits.CropEach(d, boxes), Selected(), status);
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

    private int _blankRevision;

    private void ClearBlank()
    {
        BlankList.Items.Clear();
        BlankHint.Text = "";
    }

    private async void FindBlank_Click(object sender, RoutedEventArgs e) => await FindBlanks();

    private async Task FindBlanks()
    {
        if (Tab is not { CanDraw: true } tab || Host is not { } host) return;
        byte[] bytes = tab.Session.Current.ToArray();
        int revision = tab.Revision;
        var source = Exporter.Source(tab, new WicImageCodec());
        var annotated = tab.Document.Pages.Select(page => PdfAnnotations.Read(tab.Document, page).Any(a => a.Type is not (AnnotationType.Link or AnnotationType.Popup))).ToList();
        List<int>? blank = null;
        IReadOnlyList<OcrPageKind>? pageKinds = null;
        await host.RunBusyAsync(Loc.T("Looking for blank pages"), token => Task.Run(() =>
        {
            var kinds = OcrPages.Classify(bytes, tab.Password, tab.Certificate);
            pageKinds = kinds;
            using var drawn = Exporter.Snapshot(source);
            if (drawn is null) return;
            var ink = new bool?[kinds.Count];
            for (int i = 0; i < kinds.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                int done = i + 1;
                if (i % 10 == 0) Dispatcher.BeginInvoke(() => host.SetBusyText(Loc.T("Looking at page {0} of {1}", done, kinds.Count)));
                if (drawn.Render(i, 72) is { } image) ink[i] = PageInk.IsBlank(image);
            }
            blank = PageEdits.BlankPages(kinds, ink, annotated);
        }, token));
        if (blank is null || !ReferenceEquals(Tab, tab) || tab.Revision != revision) return;
        ClearBlank();
        _blankRevision = revision;
        foreach (int page in blank) BlankList.Items.Add(new CheckBox { Content = Cells[page].Name, Tag = page, IsChecked = pageKinds![page] == OcrPageKind.Blank, Margin = new Thickness(0, 2, 0, 2) });
        BlankHint.Text = blank.Count == 0 ? Loc.T("No blank pages found.") : Loc.Plural(blank.Count, "{0} blank page found.", "{0} blank pages found.", blank.Count);
        if (blank.Count == Cells.Count)
        {
            ((CheckBox)BlankList.Items[0]!).IsChecked = false;
            BlankHint.Text = Loc.T("Every page looks blank. The first is kept.");
        }
        Refresh();
    }

    private void BlankCheck_Click(object sender, RoutedEventArgs e) => Refresh();

    private void DeleteBlank()
    {
        var pages = BlankList.Items.Cast<CheckBox>().Where(c => c.IsChecked == true).Select(c => (int)c.Tag).ToList();
        if (pages.Count == 0 || pages.Count == Cells.Count) return;
        PageJobs.Delete(Tab!, Host!, Loc.T("Delete blank pages"), pages, Loc.Plural(pages.Count, "{0} blank page deleted", "{0} blank pages deleted", pages.Count));
    }
}
