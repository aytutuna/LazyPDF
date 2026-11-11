using System.Windows;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <summary>
/// The two files side by side, or the new one with what differs painted over it. The panel owns the comparison;
/// this window shows it and goes where the change list says.
/// </summary>
internal sealed partial class CompareWindow : Window
{
    private readonly CompareSession _session;
    private readonly IDocumentViewer _old = ViewerFactory.Create(false);
    private readonly IDocumentViewer _new = ViewerFactory.Create(false);
    private readonly ViewSync _sync;
    private IReadOnlyList<ChangeRow> _rows;
    private bool _overlay;

    public CompareWindow(CompareSession session, IReadOnlyList<ChangeRow> rows)
    {
        _session = session;
        _rows = rows;
        _sync = new ViewSync(_old, _new, session.Result!.Pages);
        InitializeComponent();
        Title = Loc.T("Comparison of {0} and {1}", session.Old.Title, session.New.Title);
        OldTitle.Text = Loc.T("Old: {0}", session.Old.Title);
        NewTitle.Text = Loc.T("New: {0}", session.New.Title);
        LegendText.Text = session.ByPixels ? Loc.T("Blue marks places that look different.") : CompareText.Legend;
        OldHost.Content = _old.View;
        NewHost.Content = _new.View;
        _old.Show(session.Old);
        _new.Show(session.New);
        _old.Fit = FitMode.Width;
        _new.Fit = FitMode.Width;
        _old.ViewChanged += Viewer_ViewChanged;
        _new.ViewChanged += Viewer_ViewChanged;
        Changes.Picked += (_, row) => Go(row);
        Closed += Window_Closed;
        Rows = rows;
    }

    public IReadOnlyList<ChangeRow> Rows
    {
        get => _rows;
        set
        {
            _rows = value;
            Changes.Rows = value;
            DrawMarks();
        }
    }

    public void Go(ChangeRow row)
    {
        if (!_overlay) Show(_old, row.OldPage, row.OldArea);
        Show(_new, row.NewPage, row.NewArea);
    }

    private static void Show(IDocumentViewer viewer, int page, Rect? area)
    {
        if (page < 0 || page >= viewer.PageCount) return;
        if (area is { } rect) viewer.Reveal(page, rect);
        else viewer.GoToPage(page);
    }

    private void Layout_Click(object sender, RoutedEventArgs e)
    {
        _overlay = OverlayButton.IsChecked == true;
        OldColumn.Width = _overlay ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        OldPane.Visibility = _overlay ? Visibility.Collapsed : Visibility.Visible;
        LinkToggle.IsEnabled = !_overlay;
        ShowOverlays();
    }

    private void Link_Click(object sender, RoutedEventArgs e) => _sync.Enabled = LinkToggle.IsChecked == true;

    private void Window_Closed(object? sender, EventArgs e)
    {
        _closed = true;
        _sync.Detach();
        _old.ViewChanged -= Viewer_ViewChanged;
        _new.ViewChanged -= Viewer_ViewChanged;
        _old.Show(null);
        _new.Show(null);
    }
}
