using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// Going places: pages, destinations, the history, the page box, the find bar and the prompt before an address opens.
public partial class PageViewer
{
    private readonly PageHistory _history = new();
    private string? _pendingAddress;

    public bool CanGoBack => _history.CanGoBack;

    public bool CanGoForward => _history.CanGoForward;

    public void GoToPage(int page)
    {
        if (_tab is null || Surface.PageCount == 0) return;
        page = Math.Clamp(page, 0, Surface.PageCount - 1);
        _history.Jump(Surface.CurrentPage, page);
        Surface.GoToPage(page);
    }

    // The next or previous page, or spread when facing pages show.
    private void StepPage(int direction)
    {
        if (Surface.PageCount == 0) return;
        int spread = ViewLayout.SpreadOf(Surface.Columns, Surface.Cover, Surface.CurrentPage) + direction;
        if (spread < 0 || spread >= ViewLayout.SpreadsOf(Surface.Columns, Surface.Cover, Surface.PageCount)) return;
        GoToPage(ViewLayout.PagesOf(Surface.Columns, Surface.Cover, spread, Surface.PageCount).First);
    }

    public void GoToDestination(PdfDestination destination)
    {
        if (_tab is null || PdfDestinations.Locate(_tab.Document, destination) is not { } place) return;
        _history.Jump(Surface.CurrentPage, place.PageIndex);
        Surface.GoToPage(place.PageIndex, new Point(place.X, Math.Max(0, place.Y - 12)));
    }

    public void FollowAction(PdfAction? action)
    {
        switch (action)
        {
            case GoToAction go:
                GoToDestination(go.Destination);
                break;
            case UriAction uri:
                AskToOpen(uri.Uri);
                break;
            case NamedAction named:
                Named(named.Name);
                break;
        }
    }

    private void Named(string name)
    {
        switch (name)
        {
            case "NextPage": StepPage(1); break;
            case "PrevPage": StepPage(-1); break;
            case "FirstPage": GoToPage(0); break;
            case "LastPage": GoToPage(Surface.PageCount - 1); break;
            case "GoBack": GoBack(); break;
            case "GoForward": GoForward(); break;
            case "Find": ShowFind(); break;
        }
    }

    public void GoBack()
    {
        if (_history.Back(Surface.CurrentPage) is { } page) Surface.GoToPage(page);
    }

    public void GoForward()
    {
        if (_history.Forward(Surface.CurrentPage) is { } page) Surface.GoToPage(page);
    }

    public void Reveal(int page, Rect area) => Surface.Reveal(page, area);

    // ----- The page box

    public void ShowGoToPage()
    {
        if (_tab is null) return;
        if (Bar.Visibility != Visibility.Visible) ReadingMode = false;
        PageBox.Focus();
    }

    private void PageBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => PageBox.SelectAll();

    private void PageBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => RefreshBar();

    private void PageBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            string text = PageBox.Text.Trim();
            int? page = _tab is null ? null : PdfPageLabels.Find(_tab.Document, text) ?? (int.TryParse(text, out int number) ? number - 1 : null);
            if (page is { } target && target >= 0 && target < Surface.PageCount) GoToPage(target);
            Surface.Focus();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            Surface.Focus();
            e.Handled = true;
        }
    }

    // ----- Find

    public ViewerSearch Search { get; }

    public void ShowFind()
    {
        if (_tab is null) return;
        if (_reading) ReadingMode = false;
        Find.Visibility = Visibility.Visible;
        string? selected = _selection.IsEmpty || _selection.Start.Page != _selection.End.Page ? null : SelectedOnOnePage();
        Find.Open(selected);
    }

    private void HideFind()
    {
        if (Find.Visibility != Visibility.Visible) return;
        Find.Visibility = Visibility.Collapsed;
        Search.Clear();
        Surface.Focus();
    }

    private void Search_Changed(object? sender, EventArgs e)
    {
        _hitGeometry.Clear();
        Surface.InvalidateVisual();
    }

    private void Search_CurrentChanged(object? sender, EventArgs e)
    {
        if (Search.Current < 0 || Search.Current >= Search.Hits.Count) return;
        var hit = Search.Hits[Search.Current].Match;
        if (_tab is null || hit.Quads.Count == 0) return;
        var area = PageBounds(hit.Page, hit.Quads);
        _history.Jump(Surface.CurrentPage, hit.Page);
        Surface.Reveal(hit.Page, area);
        _hitGeometry.Clear();
        Surface.InvalidateVisual();
    }

    // ----- Addresses

    private static readonly string[] OpenableSchemes = ["http", "https", "mailto"];

    // An address in a file is the file's, not the reader's: it is shown and asked about, and only the usual schemes are opened.
    private void AskToOpen(string address)
    {
        address = address.Trim();
        if (!Uri.TryCreate(address, UriKind.Absolute, out _) && address.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
            address = "https://" + address;
        bool openable = Uri.TryCreate(address, UriKind.Absolute, out var uri) && OpenableSchemes.Contains(uri.Scheme);
        _pendingAddress = openable ? address : null;
        LinkTitle.Text = openable ? Loc.T("Open this link?") : Loc.T("This link cannot be opened.");
        LinkAddress.Text = address;
        LinkOpen.Visibility = openable ? Visibility.Visible : Visibility.Collapsed;
        LinkCancel.Content = openable ? Loc.T("Cancel") : Loc.T("Close");
        LinkCard.Visibility = Visibility.Visible;
        (openable ? LinkOpen : LinkCancel).Focus();
    }

    private void HideLink()
    {
        _pendingAddress = null;
        LinkCard.Visibility = Visibility.Collapsed;
    }

    private void LinkCancel_Click(object sender, RoutedEventArgs e)
    {
        HideLink();
        Surface.Focus();
    }

    private void LinkOpen_Click(object sender, RoutedEventArgs e)
    {
        string? address = _pendingAddress;
        HideLink();
        Surface.Focus();
        if (address is null) return;
        try
        {
            Process.Start(new ProcessStartInfo(address) { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // No program is set up for the address; nothing more to do.
        }
    }
}
