using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Panels.Signatures;

/// <summary>
/// The signatures of the file and what Core found when it checked them. A click shows the field; the details
/// say what changed since, what is wrong and what could not be checked, and offer the signed version of the file.
/// </summary>
public partial class SignaturesSidePanel : ToolPanel
{
    private int _ticket;

    public SignaturesSidePanel()
    {
        InitializeComponent();
        ShowTrust();
    }

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        ShowTrust();
        _ = BuildAsync();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _ticket++;
        List.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => _ = BuildAsync();

    private async Task BuildAsync()
    {
        int ticket = ++_ticket;
        var tab = Tab!;
        Show(null, Loc.T("Checking the signatures"));
        var bytes = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        var options = SigningSettingsStore.Load().Verify(password, certificate, DateTimeOffset.Now);
        IReadOnlyList<SignatureReport>? reports;
        Dictionary<string, (int Page, PdfRect Rect)> fields = [];
        try
        {
            (reports, fields) = await Task.Run(() => (PdfSignatureVerifier.Verify(bytes, options), SignatureFields.Locate(bytes, password, certificate)));
        }
        catch (PdfReadException)
        {
            reports = null;
        }
        if (ticket != _ticket) return;
        if (reports is null) Show(null, Loc.T("The signatures could not be checked."));
        else Show(reports.Select(r => Row(r, fields)).ToList(), reports.Count == 0 ? Loc.T("This file has no signatures.") : null);
        if (reports is { Count: > 0 }) List.SelectedIndex = 0;
    }

    private void Show(List<SignatureRow>? rows, string? note)
    {
        List.ItemsSource = rows;
        Details.Visibility = Visibility.Collapsed;
        Note.Text = note ?? "";
        Note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private SignatureRow Row(SignatureReport report, Dictionary<string, (int Page, PdfRect Rect)> fields)
    {
        if (report.FieldName is null || !fields.TryGetValue(report.FieldName, out var at)) return new SignatureRow(report, -1, Rect.Empty);
        var box = Viewer!.Geometry(at.Page).ToDisplay(at.Rect);
        return new SignatureRow(report, at.Page, new Rect(box.X, box.Y, box.Width, box.Height));
    }

    private void Go(SignatureRow row)
    {
        if (row.Page < 0 || Viewer is not { } viewer) return;
        viewer.GoToPage(row.Page);
        viewer.Reveal(row.Page, row.Where);
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (List.SelectedItem is not SignatureRow row)
        {
            Details.Visibility = Visibility.Collapsed;
            return;
        }
        Sections.ItemsSource = row.Sections;
        Details.Visibility = Visibility.Visible;
        bool copy = row.HasLaterRevisions;
        bool locked = Tab!.Document.IsEncrypted;
        ViewButton.IsEnabled = copy && !locked;
        RestoreButton.IsEnabled = copy;
        VersionNote.Text = !copy ? Loc.T("This is the signed version.") : locked ? Loc.T("A protected file cannot open as a copy. Save the signed version, then open it.") : "";
        VersionNote.Visibility = VersionNote.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void List_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is SignatureRow row) Go(row);
    }

    private void List_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && List.SelectedItem is SignatureRow row)
        {
            Go(row);
            e.Handled = true;
        }
    }

    private async void View_Click(object sender, RoutedEventArgs e)
    {
        if (List.SelectedItem is not SignatureRow row) return;
        if (SignedVersion.Of(Tab!.Session.Current.ToArray(), row.Report) is not { } bytes)
        {
            Tell(Loc.T("The signed version is not in the file's history."));
            return;
        }
        await Host!.OpenNewAsync(bytes, Loc.T("{0} (signed by {1})", System.IO.Path.GetFileNameWithoutExtension(Tab.Title), row.Title));
    }

    private void Restore_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        if (List.SelectedItem is not SignatureRow row) return;
        if (SignedVersion.Of(tab.Session.Current.ToArray(), row.Report) is not { } bytes)
        {
            Tell(Loc.T("The signed version is not in the file's history."));
            return;
        }
        var dialog = new SaveFileDialog
        {
            Title = Loc.T("Save the signed version"),
            Filter = "PDF|*.pdf",
            FileName = Loc.T("{0} (signed)", System.IO.Path.GetFileNameWithoutExtension(tab.Title)) + ".pdf",
        };
        if (dialog.ShowDialog() != true) return;
        if (string.Equals(System.IO.Path.GetFullPath(dialog.FileName), tab.Path is null ? null : System.IO.Path.GetFullPath(tab.Path), StringComparison.OrdinalIgnoreCase))
        {
            Tell(Loc.T("That is the open file. Choose another name."));
            return;
        }
        try
        {
            if (tab.Certificate is { } certificate) PdfFileSaver.Save(dialog.FileName, bytes, certificate);
            else PdfFileSaver.Save(dialog.FileName, bytes, tab.Password);
            var host = Host!;
            string saved = dialog.FileName;
            host.SetStatus(Loc.T("Signed version saved."));
            host.ShowNotice(Loc.T("Signed version saved"), System.IO.Path.GetFileName(saved), new NoticeAction(Loc.T("Open it"), () => _ = host.OpenAsync(saved)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PdfReadException)
        {
            Tell(Loc.T("The file could not be saved. Check the folder and try again."));
        }
    }

    private void Tell(string text)
    {
        VersionNote.Text = text;
        VersionNote.Visibility = Visibility.Visible;
    }
}
