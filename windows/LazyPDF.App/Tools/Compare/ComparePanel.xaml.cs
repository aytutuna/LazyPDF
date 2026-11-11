using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Compare;

/// <summary>
/// Compares the open file with another file or with one of its own earlier versions. The list of differences
/// jumps to each in the stage and, when the side by side window is open, in both of its views. A finished
/// comparison stays with the tab it was run for until that tab is compared again.
/// </summary>
public partial class ComparePanel : ToolPanel
{
    private readonly Func<IDocumentRenderer> _renderers;
    private readonly IFontSource _fonts;
    private readonly ToolAction _action;
    private readonly ConditionalWeakTable<DocumentTab, HeldComparison> _held = [];
    private CompareFlow? _flow;
    private HeldComparison? _shown;
    private string? _path;
    private IReadOnlyList<PdfVersion> _versions = [];

    public ComparePanel() : this(() => new WindowsPageRenderer(), new SystemFontSource())
    {
    }

    internal ComparePanel(Func<IDocumentRenderer> renderers, IFontSource fonts)
    {
        _renderers = renderers;
        _fonts = fonts;
        _action = new ToolAction(Loc.T("Compare"), "", CanRun, RunAsync);
        InitializeComponent();
        Changes.Picked += (_, row) => Go(row);
        ShowHow();
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        _flow = new CompareFlow(Host!, _renderers, _fonts);
        Tab!.Changed += Tab_Changed;
        ShowVersions(null);
        HideUnlock();
        _held.TryGetValue(Tab, out var held);
        SetPath(held?.Path);
        Show(held);
        RaiseActionChanged();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Show(null);
        _flow = null;
    }

    private bool CanRun() => Tab is not null && (VersionMode.IsChecked == true ? VersionBox.SelectedIndex >= 0 : _path is not null);

    private async Task RunAsync()
    {
        var tab = Tab!;
        var flow = _flow!;
        bool version = VersionMode.IsChecked == true;
        var options = new CompareOptions(IgnoreCase.IsChecked == true, IgnoreSpace.IsChecked == true, IgnoreEdges.IsChecked == true);
        string? password = OtherPassword.Password.Length > 0 ? OtherPassword.Password : null;
        var request = new CompareRequest(version ? null : _path, version ? _versions[VersionBox.SelectedIndex] : null, !version && OlderToggle.IsChecked == true, options,
            PixelMode.IsChecked == true, password, (OtherCertificate.SelectedItem as CertificateChoice)?.Certificate);
        int revision = tab.Revision;
        var made = await flow.RunAsync(tab, request);
        bool here = ReferenceEquals(Tab, tab);
        if (made is null)
        {
            if (here && flow.Locked is { } locked) AskToUnlock(locked, password is not null || request.Certificate is not null);
            return;
        }
        if (_held.TryGetValue(tab, out var old))
        {
            old.Dispose();
            _held.Remove(tab);
        }
        var held = new HeldComparison(made, request.Path, !request.FileIsOlder, revision);
        _held.Add(tab, held);
        if (!here) return;
        HideUnlock();
        Show(held);
        _ = Dispatcher.BeginInvoke(new Action(ResultGroup.BringIntoView), DispatcherPriority.Loaded);
    }

    private void Show(HeldComparison? held)
    {
        _shown = held;
        ResultGroup.Visibility = held is null ? Visibility.Collapsed : Visibility.Visible;
        if (held is null) Changes.Rows = [];
        else Refresh();
    }

    private void ShowVersions(int? keep)
    {
        _versions = CompareFlow.Earlier(Tab!.Session);
        VersionBox.ItemsSource = _versions.Select(v => Loc.T("Version {0}", v.Number)).ToList();
        int at = _versions.ToList().FindIndex(v => v.Number == keep);
        VersionBox.SelectedIndex = at >= 0 ? at : _versions.Count - 1;
        VersionBox.IsEnabled = _versions.Count > 0;
        NoVersions.Visibility = _versions.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SetPath(string? path)
    {
        _path = path;
        ChosenText.Text = path is null ? Loc.T("No file chosen") : System.IO.Path.GetFileName(path);
        ChosenText.ToolTip = path;
    }

    private void AskToUnlock(PdfReadProblem problem, bool tried)
    {
        bool certificate = problem == PdfReadProblem.CertificateRequired;
        string name = System.IO.Path.GetFileName(_path!);
        UnlockText.Text = tried ? Loc.T("{0} did not open. Check it and compare again.", name)
            : certificate ? Loc.T("{0} is locked for certificate holders. Pick one that opens it.", name)
            : Loc.T("{0} is locked. Type its password.", name);
        OtherPassword.Visibility = certificate ? Visibility.Collapsed : Visibility.Visible;
        OtherCertificate.Visibility = certificate ? Visibility.Visible : Visibility.Collapsed;
        if (certificate && OtherCertificate.ItemsSource is null)
        {
            var choices = WindowsCertificates.WithPrivateKey();
            OtherCertificate.ItemsSource = choices;
            if (choices.Count == 0) UnlockText.Text = Loc.T("No certificate with a private key was found on this computer.");
        }
        UnlockGroup.Visibility = Visibility.Visible;
        (certificate ? (Control)OtherCertificate : OtherPassword).Focus();
        Host?.SetStatus(Loc.T("File is locked."));
    }

    private void HideUnlock()
    {
        UnlockGroup.Visibility = Visibility.Collapsed;
        OtherPassword.Clear();
        OtherCertificate.SelectedIndex = -1;
    }

    private Parts CurrentParts()
    {
        var parts = (Parts)0;
        if (ShowText.IsChecked == true) parts |= Parts.Text;
        if (ShowPictures.IsChecked == true) parts |= Parts.Pictures;
        if (ShowNotes.IsChecked == true) parts |= Parts.Annotations;
        if (ShowForms.IsChecked == true) parts |= Parts.Forms;
        if (ShowPages.IsChecked == true) parts |= Parts.Pages;
        if (ShowDetails.IsChecked == true) parts |= Parts.Details;
        return parts;
    }

    private void Refresh()
    {
        if (_shown is not { } held) return;
        var rows = held.Session.Rows(CurrentParts());
        Changes.Rows = rows;
        SummaryText.Text = CompareFlow.Headline(held.Session, rows.Count);
        string? note = CompareFlow.Note(held.Session);
        NoteText.Text = note;
        NoteText.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        if (held.Window is { } open) open.Rows = rows;
    }

    private void Go(ChangeRow row)
    {
        if (_shown is not { } held) return;
        if (held.Window is { } open)
        {
            open.Go(row);
            return;
        }
        if (row.OldPage < 0 && row.NewPage < 0) return;
        if (Tab?.Revision != held.Revision)
        {
            Host?.SetStatus(Loc.T("File changed. Compare again."));
            return;
        }
        int page = held.OpenIsNew ? row.NewPage : row.OldPage;
        var area = held.OpenIsNew ? row.NewArea : row.OldArea;
        if (page < 0 || Viewer is not { } viewer)
        {
            Host?.SetStatus(Loc.T("Only in the other file."));
            return;
        }
        if (area is { } rect) viewer.Reveal(page, rect);
        else viewer.GoToPage(page);
    }

    private void ShowHow() =>
        HowText.Text = PixelMode.IsChecked == true ? Loc.T("Compares how the pages look. Use it for scans and drawings.")
            : Loc.T("Compares words, fonts, pictures, notes and form values.");

    private void Tab_Changed(object? sender, EventArgs e)
    {
        ShowVersions(VersionBox.SelectedIndex >= 0 ? _versions[VersionBox.SelectedIndex].Number : null);
        RaiseActionChanged();
    }

    private void Source_Click(object sender, RoutedEventArgs e)
    {
        bool version = VersionMode.IsChecked == true;
        FileGroup.Visibility = version ? Visibility.Collapsed : Visibility.Visible;
        VersionGroup.Visibility = version ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    private void How_Click(object sender, RoutedEventArgs e)
    {
        bool pixels = PixelMode.IsChecked == true;
        OptionGroup.IsEnabled = !pixels;
        FilterGrid.IsEnabled = !pixels;
        ShowLabel.Opacity = pixels ? 0.5 : 1;
        ShowHow();
    }

    private void Version_Changed(object sender, SelectionChangedEventArgs e) => RaiseActionChanged();

    private void Choose_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("PDF files") + "|*.pdf" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        SetPath(dialog.FileName);
        HideUnlock();
        RaiseActionChanged();
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        string? pdf = paths.FirstOrDefault(p => string.Equals(System.IO.Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase));
        if (pdf is null)
        {
            Host?.SetStatus(Loc.T("Only PDF files can be added."));
            return;
        }
        FileMode.IsChecked = true;
        Source_Click(this, e);
        SetPath(pdf);
        HideUnlock();
        RaiseActionChanged();
    }

    private void Filter_Click(object sender, RoutedEventArgs e) => Refresh();

    private void View_Click(object sender, RoutedEventArgs e)
    {
        if (_shown is not { } held) return;
        if (held.Window is { } open)
        {
            open.Activate();
            return;
        }
        var window = new CompareWindow(held.Session, held.Session.Rows(CurrentParts())) { Owner = Window.GetWindow(this) };
        window.Closed += (_, _) => held.Window = null;
        held.Window = window;
        window.Show();
    }

    private async void Report_Click(object sender, RoutedEventArgs e)
    {
        if (_shown is not { } held || _flow is not { } flow) return;
        ReportButton.IsEnabled = false;
        try
        {
            await flow.WriteReportAsync(held.Session, CurrentParts());
        }
        finally
        {
            ReportButton.IsEnabled = true;
        }
    }
}
