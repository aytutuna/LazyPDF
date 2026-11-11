using System.Windows;
using LazyPDF.App.Tools.Optimize;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Sanitize;

/// <summary>Clean for sharing: what the file holds that others could read, a switch for each kind, and the run.</summary>
public sealed partial class SanitizePanel : ToolPanel
{
    private readonly ToolAction _action;
    private List<SanitizeRow> _rows = [];

    public SanitizePanel()
    {
        InitializeComponent();
        _action = new ToolAction(Loc.T("Clean file"), "", () => Tab is not null && _rows.Any(r => r.IsChecked), RunAsync);
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Output.Configure(Tab, removesSignatures: true);
        _ = ScanAsync();
    }

    protected override void OnDetach() => Tab!.Changed -= Tab_Changed;

    private void Tab_Changed(object? sender, EventArgs e)
    {
        Output.Configure(Tab!, removesSignatures: true);
        _ = ScanAsync();
    }

    private async Task ScanAsync()
    {
        if (Tab is not { } tab) return;
        _rows = [];
        Rows.ItemsSource = null;
        RaiseActionChanged();
        if (OptimizeJob.NeedsOwner(tab.Document))
        {
            Found.Text = Loc.T("This file is protected. Open it with its owner password to use this tool.");
            return;
        }
        Found.Text = Loc.T("Looking through the file.");
        byte[] file = tab.Session.Current.ToArray();
        int revision = tab.Revision;
        IReadOnlyList<SanitizeFinding> findings;
        try
        {
            findings = await Task.Run(() => SanitizeJob.Scan(file, tab.Password, tab.Certificate));
        }
        catch (Exception e) when (e is PdfReadException or InvalidOperationException)
        {
            if (ReferenceEquals(Tab, tab) && tab.Revision == revision) Found.Text = Loc.T("The file could not be searched.");
            return;
        }
        if (!ReferenceEquals(Tab, tab) || tab.Revision != revision) return;
        _rows = [.. findings.Select(f => new SanitizeRow(f))];
        Rows.ItemsSource = _rows;
        Found.Text = _rows.Count == 0 ? Loc.T("Nothing found of the kinds listed here. Text inside pictures is not looked at.") : Loc.T("Tick what to remove.");
        RaiseActionChanged();
    }

    private void Row_Click(object sender, RoutedEventArgs e) => RaiseActionChanged();

    private async Task RunAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var ticked = _rows.Where(r => r.IsChecked).Select(r => r.Item).ToHashSet();
        bool replace = Output.Replace;
        if (OutputWriter.Refuses(host, tab, replace)) return;
        int revision = tab.Revision;
        byte[] file = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        string title = Loc.T("{0} (clean)", Path.GetFileNameWithoutExtension(tab.Title)) + ".pdf";

        SanitizeResult? result = null;
        await host.RunBusyAsync(Loc.T("Cleaning the file"), async token =>
            result = await Task.Run(() => SanitizeJob.Run(file, password, certificate, ticked, token), token).WaitAsync(token));
        if (result is null) return;
        if (!await OutputWriter.DeliverAsync(host, tab, revision, result.Bytes, replace, title)) return;

        string text = result.Removed.Count > 0 ? Loc.T("Removed: {0}.", SanitizeJob.List(result.Removed)) : Loc.T("Nothing was removed.");
        if (result.Kept.Count > 0) text += " " + Loc.T("Left in: {0}.", SanitizeJob.List(result.Kept));
        host.ShowNotice(Loc.T("File cleaned"), text);
        host.SetStatus(Loc.T("File cleaned."));
    }
}
