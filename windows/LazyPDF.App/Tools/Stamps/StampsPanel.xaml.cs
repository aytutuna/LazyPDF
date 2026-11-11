using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Stamps;

public enum StampMode
{
    Watermark,
    Background,
    HeaderFooter,
    Bates,
}

/// <summary>
/// Watermarks, backgrounds, headers, footers and Bates numbers. The form describes one stamp, the pages show it as
/// it is typed, and the action writes it; the runs already in the file are listed to update or remove.
/// </summary>
public sealed partial class StampsPanel : ToolPanel
{
    private readonly SystemFontSource _fonts = new();
    private readonly WicImageCodec _codec = new();
    private readonly string[] _families;
    private readonly (string Name, StampColor Color)[] _colors =
    [
        (Loc.T("Grey"), StampColor.Gray(0.5)),
        (Loc.T("Black"), StampColor.Black),
        (Loc.T("Red"), new StampColor(0.8, 0.1, 0.1)),
        (Loc.T("Orange"), new StampColor(0.95, 0.5, 0.1)),
        (Loc.T("Green"), new StampColor(0.1, 0.55, 0.25)),
        (Loc.T("Blue"), new StampColor(0.1, 0.35, 0.8)),
    ];
    private readonly (string Name, StampColor? Color)[] _backColors =
    [
        (Loc.T("None"), null),
        (Loc.T("White"), new StampColor(1, 1, 1)),
        (Loc.T("Light grey"), StampColor.Gray(0.9)),
        (Loc.T("Cream"), new StampColor(1, 0.97, 0.85)),
        (Loc.T("Light blue"), new StampColor(0.85, 0.92, 1)),
    ];

    private readonly Dictionary<(Guid Tab, int Run), StampDraft> _written = [];
    private bool _ready;
    private bool _reading;
    private bool _canRun;
    private bool _touched;
    private ToolAction? _action;
    private byte[]? _picture;
    private ImageSource? _pictureImage;

    public StampsPanel()
    {
        InitializeComponent();
        var installed = Fonts.SystemFontFamilies.SelectMany(f => f.FamilyNames.Values).ToHashSet(StringComparer.OrdinalIgnoreCase);
        _families = ["Helvetica", "Times", "Courier", .. new[] { "Arial", "Calibri", "Georgia", "Verdana", "Segoe UI", "Consolas" }.Where(installed.Contains)];
        FontFamilyBox.ItemsSource = _families;
        FontFamilyBox.SelectedIndex = 0;
        ColorBox.ItemsSource = _colors.Select(c => c.Name).ToList();
        ColorBox.SelectedIndex = 0;
        BackColorBox.ItemsSource = _backColors.Select(c => c.Name).ToList();
        BackColorBox.SelectedIndex = 2;
        WatermarkText.Text = Loc.T("Confidential");
        BoldBox.IsChecked = true;
        TokensHint.Text = Loc.T("{page}, {pages}, {date} and {file} fill in by themselves.");
        _ready = true;
        ShowMode();
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Viewer!.ViewChanged += Viewer_ViewChanged;
        _previewOn = true;
        _touched = false;
        BuildRuns();
        Refresh();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Viewer!.ViewChanged -= Viewer_ViewChanged;
        ClearPreviews();
        _loading = true;
        RunList.ItemsSource = null;
        _loading = false;
        _selected = null;
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        BuildRuns();
        Refresh();
    }

    private void Kind_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        // Each kind starts from what suits it; what the user changes afterwards stays.
        bool text = Mode is StampMode.HeaderFooter or StampMode.Bates;
        BoldBox.IsChecked = Mode == StampMode.Watermark;
        ColorBox.SelectedIndex = text ? 1 : 0;
        OpacitySlider.Value = Mode == StampMode.Background ? 100 : 30;
        ShowMode();
        Form_Changed(sender, e);
    }

    private void ShowMode()
    {
        var mode = Mode;
        static Visibility Shown(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
        WatermarkBox.Visibility = Shown(mode == StampMode.Watermark);
        BackgroundBox.Visibility = Shown(mode == StampMode.Background);
        PictureBox.Visibility = Shown(mode is StampMode.Watermark or StampMode.Background);
        OpacityBox.Visibility = Shown(mode is StampMode.Watermark or StampMode.Background);
        BandsBox.Visibility = Shown(mode == StampMode.HeaderFooter);
        BatesBox.Visibility = Shown(mode == StampMode.Bates);
        FontBox.Visibility = Shown(mode != StampMode.Background);
        TextSizeBox.Visibility = Shown(mode is StampMode.HeaderFooter or StampMode.Bates);
    }

    private void Form_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _touched = true;
        _previewOn = true;
        Refresh();
    }

    private void Refresh()
    {
        if (!_ready || Tab is null) return;
        PagesText.Visibility = PagesBox.SelectedIndex == (int)PageSet.Typed ? Visibility.Visible : Visibility.Collapsed;
        ScaleReadout.Text = Loc.T("{0} %", (int)ScaleSlider.Value);
        TurnReadout.Text = Loc.T("{0}°", (int)TurnSlider.Value);
        OpacityReadout.Text = Loc.T("{0} %", (int)OpacitySlider.Value);
        TextSizeReadout.Text = Loc.T("{0} pt", (int)TextSizeSlider.Value);
        MarginReadout.Text = Loc.T("{0} pt", (int)MarginSlider.Value);

        ReadDraft(out string? problem);
        _canRun = problem is null;
        ProblemText.Text = problem ?? "";
        ProblemRow.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateAction();
        UpdatePreview();
    }

    private void UpdateAction()
    {
        string text = _selected is not null ? Loc.T("Update stamp") : Mode switch
        {
            StampMode.Watermark => Loc.T("Add watermark"),
            StampMode.Background => Loc.T("Add background"),
            StampMode.HeaderFooter => Loc.T("Add header and footer"),
            _ => Loc.T("Add Bates numbers"),
        };
        if (_action?.Text != text) _action = new ToolAction(text, "", () => _canRun && IsEnabled && (_selected is null || _touched), RunAsync);
        RaiseActionChanged();
    }

    private Task RunAsync()
    {
        var tab = Tab!;
        var host = Host!;
        if (ReadDraft(out _) is not { } draft) return Task.CompletedTask;
        int? replace = _selected?.Id;
        return ChangeGate.RunAsync(tab, host, _action!.Text, () => Working(() => StampAsync(tab, host, draft, replace)));
    }

    private async Task Working(Func<Task> run)
    {
        IsEnabled = false;
        RaiseActionChanged();
        try
        {
            await run();
        }
        finally
        {
            IsEnabled = true;
            RaiseActionChanged();
        }
    }

    // False when the work was cancelled or failed, or the document was swapped by Undo meanwhile; the document goes back to its last commit then.
    private static async Task<bool> EditAsync(DocumentTab tab, IToolHost host, string busy, Action<PdfDocument> work)
    {
        var document = tab.Document;
        bool done = false;
        try
        {
            await host.RunBusyAsync(busy, token => Task.Run(() =>
            {
                token.ThrowIfCancellationRequested();
                work(document);
                done = !token.IsCancellationRequested;
            }, token));
        }
        catch
        {
            tab.Session.Discard();
            throw;
        }
        if (!done)
        {
            tab.Session.Discard();
            host.SetStatus(Loc.T("Cancelled."));
        }
        return done && ReferenceEquals(tab.Document, document);
    }

    private async Task StampAsync(DocumentTab tab, IToolHost host, StampDraft draft, int? replace)
    {
        StampRun? run = null;
        try
        {
            if (!await EditAsync(tab, host, Loc.T("Stamping pages"), document => run = draft.Apply(document, _fonts, _codec, replace))) return;
        }
        catch (InvalidOperationException)
        {
            host.ShowProblem(new Problem(Loc.T("No font for this text"), StampsText.NoFont));
            return;
        }
        catch (InvalidDataException)
        {
            host.ShowProblem(new Problem(Loc.T("Picture cannot be read"), Loc.T("Pick a PNG, JPEG or another common picture.")));
            return;
        }

        // The page now carries the stamp; the preview would only draw it twice.
        _previewOn = false;
        ClearPreviews();
        if (!tab.Commit(replace is null ? draft.AddText : Loc.T("Update stamp")))
        {
            host.SetStatus(Loc.T("Nothing was stamped."));
            return;
        }
        _written[(tab.Id, run!.Id)] = draft;
        _touched = false;
        if (replace is null && draft.HeaderFooter?.Bates is { } bates)
        {
            Quiet(() => StartBox.Text = run.NextBates.ToString());
            host.SetStatus(Loc.T("Next number is {0}.", bates.Format(run.NextBates)));
        }
        else
        {
            host.SetStatus(Loc.Plural(run.Pages, "Stamped {0} page.", "Stamped {0} pages."));
        }
        if (run.Missing.Count > 0)
            host.ShowNotice(Loc.T("Some characters are missing"), Loc.T("The font cannot draw all of the text. Pick another font and update the stamp."));
    }

    // Sets fields without the form taking it for an edit.
    private void Quiet(Action change)
    {
        _ready = false;
        change();
        _ready = true;
        Refresh();
    }

    private async void Picture_Click(object sender, RoutedEventArgs e)
    {
        if (_reading) return;
        var dialog = new OpenFileDialog
        {
            Title = Loc.T("Pick a picture"),
            Filter = Loc.T("Pictures") + "|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|" + Loc.T("All files") + "|*.*",
        };
        if (dialog.ShowDialog() != true) return;
        await PickAsync(dialog.FileName);
    }

    internal byte[]? Picture => _picture;

    internal async Task PickAsync(string path)
    {
        var tab = Tab;
        var host = Host!;
        byte[]? bytes = null;
        ImageSource? image = null;
        _reading = true;
        PictureButton.IsEnabled = false;
        try
        {
            await host.RunBusyAsync(Loc.T("Reading the picture"), token => Task.Run(() =>
            {
                token.ThrowIfCancellationRequested();
                var upright = SignatureArt.UprightFile(File.ReadAllBytes(path));
                if (token.IsCancellationRequested) return;
                image = Decode(upright);
                bytes = upright;
            }, token));
            if (bytes is null || !ReferenceEquals(Tab, tab)) return;
            _pictureImage = image;
            _picture = bytes;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException or FileFormatException)
        {
            host.ShowProblem(new Problem(Loc.T("Picture cannot be read"), Loc.T("Pick a PNG, JPEG or another common picture.")));
            return;
        }
        finally
        {
            _reading = false;
            PictureButton.IsEnabled = true;
        }
        PictureName.Text = Path.GetFileName(path);
        ShowPicture();
        Form_Changed(this, new RoutedEventArgs());
    }

    private static ImageSource Decode(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes);
        var frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        frame.Freeze();
        return frame;
    }

    private void PictureClear_Click(object sender, RoutedEventArgs e)
    {
        _picture = null;
        _pictureImage = null;
        ShowPicture();
        Form_Changed(sender, e);
    }

    private void ShowPicture()
    {
        var shown = _picture is null ? Visibility.Collapsed : Visibility.Visible;
        PictureName.Visibility = PictureClear.Visibility = shown;
    }
}
