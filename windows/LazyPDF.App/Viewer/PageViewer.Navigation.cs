using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
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
        if (Surface.TopPlace() is { } from) _history.Jump(from, new PagePoint(page, new Point(0, 0)), Surface.Rotation);
        Surface.GoToPage(page);
        RefreshBar();
    }

    // The next or previous page, or spread when facing pages show.
    private void StepPage(int direction)
    {
        if (Surface.PageCount == 0) return;
        int spread = ViewLayout.SpreadOf(Surface.Columns, Surface.Cover, Surface.CurrentPage) + direction;
        if (spread < 0 || spread >= ViewLayout.SpreadsOf(Surface.Columns, Surface.Cover, Surface.PageCount)) return;
        Surface.GoToPage(ViewLayout.PagesOf(Surface.Columns, Surface.Cover, spread, Surface.PageCount).First);
    }

    public void GoToDestination(PdfDestination destination)
    {
        if (_tab is null) return;
        if (PdfDestinations.Locate(_tab.Document, destination) is not { } place)
        {
            Tell(Loc.T("This link goes to a page that is not in the file."), null);
            return;
        }
        var size = Surface.PageSize(place.PageIndex);
        var to = Surface.Rotation switch
        {
            90 => new Point(Math.Max(0, place.X - 12), place.Y),
            180 => new Point(place.X, Math.Min(size.Height, place.Y + 12)),
            270 => new Point(Math.Min(size.Width, place.X + 12), place.Y),
            _ => new Point(place.X, Math.Max(0, place.Y - 12)),
        };
        if (Surface.TopPlace() is { } from) _history.Jump(from, new PagePoint(place.PageIndex, to), Surface.Rotation);
        Surface.GoToPage(place.PageIndex, to);
        RefreshBar();
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
            case GoToRemoteAction remote:
                Tell(Loc.T("This link goes to another file, which Lazy PDF does not open from here."), remote.File);
                break;
            case LaunchAction launch:
                Tell(Loc.T("This link goes to another file, which Lazy PDF does not open from here."), launch.File);
                break;
            case SubmitFormAction submit:
                Tell(Loc.T("This link runs a script or sends a form, which Lazy PDF does not do."), submit.Url);
                break;
            case JavaScriptAction or ResetFormAction:
                Tell(Loc.T("This link runs a script or sends a form, which Lazy PDF does not do."), null);
                break;
            case OtherAction other:
                Tell(OtherText(other.Type), null);
                break;
            default:
                Tell(Loc.T("This link cannot be followed."), null);
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
            default: Tell(Loc.T("This link cannot be followed."), null); break;
        }
    }

    private static string OtherText(string type) => type switch
    {
        "SetOCGState" => Loc.T("This link shows or hides a layer. Use the Layers panel for that."),
        "GoToE" => Loc.T("This link goes to a file inside this file, which Lazy PDF does not open from here."),
        "Sound" or "Movie" or "Rendition" or "GoTo3DView" or "Screen" => Loc.T("This link plays sound, video or 3D content, which Lazy PDF does not do."),
        "Hide" => Loc.T("This link shows or hides part of the page, which Lazy PDF does not do."),
        _ => Loc.T("This link cannot be followed."),
    };

    public void GoBack()
    {
        if (Surface.TopPlace() is { } from && _history.Back(from) is { } place)
        {
            Surface.GoToPage(place.Page, place.Point, keepX: true);
            RefreshBar();
        }
    }

    public void GoForward()
    {
        if (Surface.TopPlace() is { } from && _history.Forward(from) is { } place)
        {
            Surface.GoToPage(place.Page, place.Point, keepX: true);
            RefreshBar();
        }
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

    private void ZoomBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => ZoomBox.SelectAll();

    private void ZoomBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => RefreshBar();

    private void ZoomBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            if (ZoomMath.Parse(ZoomBox.Text, out double zoom)) Surface.SetZoom(zoom);
            else RefreshBar();
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
        if (Search.Query.Length == 0) _searchJumped = false;
        _hitGeometry.Clear();
        Surface.InvalidateVisual();
    }

    // Back from a find returns to where the search began, so only its first move is a history entry.
    private bool _searchJumped;

    private void Search_CurrentChanged(object? sender, EventArgs e)
    {
        if (Search.Current < 0 || Search.Current >= Search.Hits.Count) return;
        var hit = Search.Hits[Search.Current].Match;
        if (_tab is null || hit.Quads.Count == 0) return;
        var area = PageBounds(hit.Page, hit.Quads);
        if (!_searchJumped && Surface.TopPlace() is { } from)
        {
            _searchJumped = _history.Jump(from, new PagePoint(hit.Page, new Point(0, area.Top)), Surface.Rotation);
        }
        Surface.Reveal(hit.Page, area);
        _hitGeometry.Clear();
        Surface.InvalidateVisual();
    }

    // ----- Addresses

    private static readonly string[] OpenableSchemes = ["http", "https", "mailto"];

    // An address in a file is the file's, not the reader's: it is shown and asked about, and only the usual schemes are opened.
    private void AskToOpen(string address)
    {
        _linkTip.IsOpen = false;
        address = WebAddress(address);
        bool openable = Uri.TryCreate(address, UriKind.Absolute, out var uri) && OpenableSchemes.Contains(uri.Scheme);
        _pendingAddress = openable ? address : null;
        LinkTitle.Text = openable ? Loc.T("Open this link?") : Loc.T("This link cannot be opened.");
        AutomationProperties.SetName(LinkCard, LinkTitle.Text);
        LinkAddress.Text = address;
        LinkAddress.Visibility = Visibility.Visible;
        LinkOpen.Visibility = openable ? Visibility.Visible : Visibility.Collapsed;
        LinkCancel.Content = openable ? Loc.T("Cancel") : Loc.T("Close");
        AutomationProperties.SetName(LinkCancel, (string)LinkCancel.Content);
        LinkCard.Visibility = Visibility.Visible;
        (openable ? LinkOpen : LinkCancel).Focus();
    }

    private void Tell(string title, string? detail)
    {
        _pendingAddress = null;
        LinkTitle.Text = title;
        AutomationProperties.SetName(LinkCard, title);
        LinkAddress.Text = detail;
        LinkAddress.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
        LinkOpen.Visibility = Visibility.Collapsed;
        LinkCancel.Content = Loc.T("Close");
        AutomationProperties.SetName(LinkCancel, (string)LinkCancel.Content);
        LinkCard.Visibility = Visibility.Visible;
        LinkCancel.Focus();
    }

    private static string WebAddress(string address)
    {
        address = address.Trim();
        if (!Uri.TryCreate(address, UriKind.Absolute, out _) && address.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
            address = "https://" + address;
        return address;
    }

    private void HideLink()
    {
        _linkTip.IsOpen = false;
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
