using System.Windows;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Optimize;

/// <summary>Make smaller: where the bytes of the file are, a preset or custom settings, and the run.</summary>
public sealed partial class OptimizePanel : ToolPanel
{
    private static readonly int[] DpiSteps = [0, 72, 96, 150, 200, 300];

    private readonly ToolAction _action;

    public OptimizePanel()
    {
        InitializeComponent();
        _action = new ToolAction(Loc.T("Make smaller"), "", () => Tab is not null && !OptimizeJob.NeedsOwner(Tab.Document), RunAsync);
        foreach (int dpi in DpiSteps) Dpi.Items.Add(dpi == 0 ? Loc.T("Keep as is") : Loc.T("{0} dpi", dpi));
        Dpi.SelectedIndex = 3;
        QualityValue.Text = Quality.Value.ToString("0");
        ShowPresetNote();
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Output.Configure(Tab, removesSignatures: false);
        _ = ShowAuditAsync();
    }

    protected override void OnDetach() => Tab!.Changed -= Tab_Changed;

    private void Tab_Changed(object? sender, EventArgs e)
    {
        Output.Configure(Tab!, removesSignatures: false);
        _ = ShowAuditAsync();
    }

    private async Task ShowAuditAsync()
    {
        if (Tab is not { } tab) return;
        Rows.ItemsSource = null;
        RaiseActionChanged();
        if (OptimizeJob.NeedsOwner(tab.Document))
        {
            Total.Text = Loc.T("This file is protected. Open it with its owner password to use this tool.");
            return;
        }
        Total.Text = Loc.T("Looking through the file.");
        byte[] file = tab.Session.Current.ToArray();
        int revision = tab.Revision;
        SpaceAudit audit;
        try
        {
            audit = await Task.Run(() => OptimizeJob.Audit(file, tab.Password, tab.Certificate));
        }
        catch (Exception e) when (e is PdfReadException or InvalidOperationException)
        {
            if (ReferenceEquals(Tab, tab) && tab.Revision == revision) Total.Text = Loc.T("The file could not be searched.");
            return;
        }
        if (!ReferenceEquals(Tab, tab) || tab.Revision != revision) return;
        Rows.ItemsSource = AuditRow.Of(audit);
        Total.Text = Loc.T("File size {0}", SizeText.Of(audit.FileSize));
    }

    private SizePreset Preset() =>
        PresetSmall.IsChecked == true ? SizePreset.Small
        : PresetHigh.IsChecked == true ? SizePreset.High
        : PresetCustom.IsChecked == true ? SizePreset.Custom
        : SizePreset.Balanced;

    private OptimizeChoice Choice() => new(Preset(),
        new CustomSize(DpiSteps[Math.Max(Dpi.SelectedIndex, 0)], (int)Quality.Value, TrimFonts.IsChecked == true, BlackWhite.IsChecked == true,
                       DropAppData.IsChecked == true, DropPrivateKeys.IsChecked == true),
        Gray.IsChecked == true, FastWeb.IsChecked == true);

    private void Preset_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized) return;
        CustomOptions.Visibility = Preset() == SizePreset.Custom ? Visibility.Visible : Visibility.Collapsed;
        ShowPresetNote();
    }

    private void Quality_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (QualityValue is not null) QualityValue.Text = Quality.Value.ToString("0");
    }

    private void ShowPresetNote()
    {
        PresetNote.Text = Preset() switch
        {
            SizePreset.Small => Loc.T("Smallest file. Pictures drop to 96 dpi and lose some detail."),
            SizePreset.Balanced => Loc.T("Good for email and screens. Pictures drop to 150 dpi and are saved as JPEG at 75%, and black and white pictures become 1-bit. Some detail is lost."),
            SizePreset.High => Loc.T("Keeps detail for printing. Pictures stay up to 300 dpi. Very little is lost."),
            _ => "",
        };
        PresetNote.Visibility = PresetNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task RunAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var choice = Choice();
        bool replace = Output.Replace;
        if (OutputWriter.Refuses(host, tab, replace)) return;
        int revision = tab.Revision;
        byte[] file = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        string title = Loc.T("{0} (smaller)", Path.GetFileNameWithoutExtension(tab.Title)) + ".pdf";

        OptimizeOutcome? outcome = null;
        await host.RunBusyAsync(Loc.T("Making the file smaller"), async token =>
            outcome = await Task.Run(() => OptimizeJob.Run(file, password, certificate, choice, new WicImageCodec(), token), token).WaitAsync(token));
        if (outcome is not { Result: var result }) return;

        long saved = result.SizeBefore - result.SizeAfter;
        if (saved <= 0 && !choice.Grayscale && !choice.FastWebView)
        {
            host.ShowNotice(Loc.T("Already small"), choice.Preset == SizePreset.Small
                ? Loc.T("This file is as small as it gets.")
                : Loc.T("These settings cannot make this file smaller. Try the Small preset."));
            return;
        }
        if (!await OutputWriter.DeliverAsync(host, tab, revision, outcome.Bytes, replace, title)) return;

        string sizes = saved > 0
            ? Loc.T("{0} to {1}, {2}% smaller.", SizeText.Of(result.SizeBefore), SizeText.Of(result.SizeAfter), SizeText.Percent(result.SizeBefore, result.SizeAfter))
            : Loc.T("{0} to {1}.", SizeText.Of(result.SizeBefore), SizeText.Of(result.SizeAfter));
        host.ShowNotice(saved > 0 ? Loc.T("File made smaller") : Loc.T("File rewritten"), string.Join(" ", [sizes, .. result.Notes]));
        host.SetStatus(saved > 0 ? Loc.T("{0} smaller.", SizeText.Of(saved)) : Loc.T("Done."));
    }
}
