using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

// Links: drag an area to make one, click one to change where it goes.
public sealed partial class EditContentPanel
{
    private int _linkPage;
    private PdfRect? _linkArea;
    private PdfLink? _linkOld;

    private void StartLink(int page, PdfRect area, PdfLink? old)
    {
        _linkPage = page;
        _linkArea = area;
        _linkOld = old;
        _surface!.ShowArea(old is null ? page : -1, old is null ? area : null);
        _surface.ActiveLink = old?.Reference;
        HideMessage();
        _loading = true;
        if (old is null)
        {
            LinkBox.Text = "";
        }
        else if (old.Uri is { } uri)
        {
            ToWeb.IsChecked = true;
            LinkBox.Text = uri;
        }
        else if (old.Destination is { PageIndex: >= 0 } destination)
        {
            ToPage.IsChecked = true;
            LinkBox.Text = (destination.PageIndex + 1).ToString();
        }
        else
        {
            LinkBox.Text = "";
            ShowMessage("", Loc.T("This link does something else. Saving replaces it."), caution: false);
        }
        _loading = false;
        RefreshPanel();
        LinkBox.Focus();
    }

    private void Surface_LinkPicked(int page, PdfLink? link)
    {
        if (link is not null) StartLink(page, link.Rect, link);
    }

    private PdfAction? LinkTarget() => PageEdits.Target(ToPage.IsChecked == true, LinkBox.Text, _tab?.PageCount ?? 0);

    private Task ApplyLinkAsync()
    {
        if (_linkArea is not { } area || LinkTarget() is not { } target) return Task.CompletedTask;
        int page = _linkPage;
        var old = _linkOld;
        if (Apply(() => _edits!.SetLink(page, area, target, old), old is null ? Loc.T("Link added.") : Loc.T("Link changed.")))
        {
            EndLink();
        }
        return Task.CompletedTask;
    }

    private void RemoveLink_Click(object sender, RoutedEventArgs e)
    {
        if (_linkOld is not { } link) return;
        int page = _linkPage;
        if (Apply(() => _edits!.RemoveLink(page, link), Loc.T("Link removed."))) EndLink();
    }

    private void EndLink()
    {
        _linkArea = null;
        _linkOld = null;
        _surface!.ShowArea(-1, null);
        _surface.ActiveLink = null;
        RefreshPanel();
    }

    private void LinkKind_Checked(object sender, RoutedEventArgs e)
    {
        if (_surface is not null && !_loading) RaiseActionChanged();
    }

    private void LinkBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_surface is not null) RaiseActionChanged();
    }

    private async void LinkBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || LinkTarget() is null) return;
        e.Handled = true;
        await ApplyLinkAsync();
    }
}
