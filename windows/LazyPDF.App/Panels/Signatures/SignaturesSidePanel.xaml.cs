using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
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

    private async Task BuildAsync(bool online = false)
    {
        int ticket = ++_ticket;
        var tab = Tab!;
        Show(null, Loc.T("Checking the signatures"));
        var bytes = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        var options = SigningSettingsStore.Load().Verify(password, certificate, DateTimeOffset.Now);
        IReadOnlyList<SignatureReport>? reports = null;
        Dictionary<string, (int Page, PdfRect Rect)> fields = [];
        using var transport = online ? new HttpSignatureTransport() : null;
        Task Work(CancellationToken token)
        {
            if (transport is not null) transport.Cancel = token;
            return Task.Run(() =>
            {
                reports = PdfSignatureVerifier.Verify(bytes, options);
                fields = SignatureFields.Locate(bytes, password, certificate);
                if (transport is not null) reports = Ask(bytes, password, transport, options, reports);
            });
        }
        try
        {
            if (online) await Host!.RunBusyAsync(Loc.T("Asking the certificate servers"), Work);
            else await Work(CancellationToken.None);
        }
        catch (PdfReadException)
        {
            reports = null;
        }
        if (ticket != _ticket) return;
        string? note = reports is { Count: 0 } ? Loc.T("This file has no signatures.") : null;
        if (online && reports is { Count: > 0 }) note = Loc.T("Checked with the certificate servers just now. The file is not changed.") + (transport!.LastFailure is { } failure ? " " + failure : "");
        if (reports is null) Show(null, Loc.T("The signatures could not be checked."));
        else Show(reports.Select(r => Row(r, fields)).ToList(), note);
        if (reports is { Count: > 0 }) List.SelectedIndex = 0;
    }

    private void Show(List<SignatureRow>? rows, string? note)
    {
        List.ItemsSource = rows;
        Details.Visibility = Visibility.Collapsed;
        Note.Text = note ?? "";
        Note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        Online.Visibility = rows is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Asks the certificate servers on a copy of the file and takes only their revocation answers into the reports.</summary>
    internal static IReadOnlyList<SignatureReport> Ask(byte[] file, string? password, ISignatureTransport transport, VerifyOptions options, IReadOnlyList<SignatureReport> reports)
    {
        try
        {
            return Merge(reports, PdfSignatureVerifier.Verify(PdfLongTermValidation.Add(file, transport, DateTimeOffset.Now, password), options));
        }
        catch (Exception error) when (error is InvalidOperationException or PdfReadException)
        {
            return reports;
        }
    }

    // Add writes a later revision, which would show as a change after every signature.
    internal static IReadOnlyList<SignatureReport> Merge(IReadOnlyList<SignatureReport> reports, IReadOnlyList<SignatureReport> asked) =>
        reports.Select(r => asked.FirstOrDefault(a => a.Index == r.Index) is { } a
            ? a with { Changes = r.Changes, Revision = r.Revision, Level = r.Level, CoversWholeFile = r.CoversWholeFile }
            : r).ToList();

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
        CertificateButton.IsEnabled = row.Report.Certificate is not null;
        CertificateButton.Content = Loc.T("View certificate");
        CertificateInfo.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(CertificateButton, row.Report.Kind == SignatureKind.DocumentTimestamp ? Loc.T("View the time stamp authority's certificate") : Loc.T("View the signer's certificate"));
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

    private void Certificate_Click(object sender, RoutedEventArgs e)
    {
        if (List.SelectedItem is not SignatureRow { Report.Certificate: { } certificate } row) return;
        bool show = CertificateInfo.Visibility != Visibility.Visible;
        if (show) CertificateText.ItemsSource = CertificateLines.Of(certificate);
        CertificateInfo.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        CertificateButton.Content = show ? Loc.T("Hide certificate") : Loc.T("View certificate");
        bool stamp = row.Report.Kind == SignatureKind.DocumentTimestamp;
        AutomationProperties.SetName(CertificateButton, show
            ? stamp ? Loc.T("Hide the time stamp authority's certificate") : Loc.T("Hide the signer's certificate")
            : stamp ? Loc.T("View the time stamp authority's certificate") : Loc.T("View the signer's certificate"));
    }

    private void CopyFingerprint_Click(object sender, RoutedEventArgs e)
    {
        if (List.SelectedItem is not SignatureRow { Report.Certificate: { } certificate }) return;
        try
        {
            Clipboard.SetText(CertificateLines.Fingerprint(certificate));
            Tell(Loc.T("Copied."));
        }
        catch (COMException)
        {
            Tell(Loc.T("The fingerprint could not be copied."));
        }
    }

    private async void CheckOnline_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        var host = Host!;
        if (tab.Certificate is not null)
        {
            Tell(Loc.T("A file protected for certificates cannot be checked online here."));
            return;
        }
        var hosts = await ServerPreview.HostsAsync(tab.Session.Current.ToArray(), tab.Password);
        if (!ReferenceEquals(Tab, tab)) return;
        if (hosts.Count == 0)
        {
            Note.Text = Loc.T("The certificates name no servers to ask.");
            Note.Visibility = Visibility.Visible;
            return;
        }
        host.ShowNotice(Loc.T("These servers will be asked"),
            Loc.T("Lazy PDF will contact {0}. Servers named by certificates found on the way may be asked too. The file itself is not sent.", ServerPreview.Describe(hosts)),
            new NoticeAction(Loc.T("Ask them"), () =>
            {
                if (ReferenceEquals(Tab, tab)) _ = BuildAsync(online: true);
            }));
    }

    private void Tell(string text)
    {
        VersionNote.Text = text;
        VersionNote.Visibility = Visibility.Visible;
    }
}
