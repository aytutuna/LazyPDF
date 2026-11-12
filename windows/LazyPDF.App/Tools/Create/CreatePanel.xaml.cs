using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Create;

/// <summary>Makes a new document from blank pages, pictures, text or the clipboard and opens it in a tab of its own.</summary>
public partial class CreatePanel : ToolPanel
{
    private sealed record PictureItem(string Path)
    {
        public string Name => System.IO.Path.GetFileName(Path);
    }

    private const int ClipboardIndex = 5;

    private readonly IImageCodec _codec = new WicImageCodec();
    private readonly IFontSource _fonts = new SystemFontSource();
    private readonly ObservableCollection<PictureItem> _pictures = [];
    private readonly ToolAction _action;
    private readonly bool _ready;
    private readonly string? _settingsDirectory;
    private readonly bool _metric = RegionInfo.CurrentRegion.IsMetric;
    private string _paperKey;
    private bool _building;
    private ClipboardKind _clipboard;
    private string? _fileProblem;
    private string? _longText;
    private string? _webPage;
    private string? _wordPath;
    private Window? _owner;

    public CreatePanel() : this(null)
    {
    }

    internal CreatePanel(string? settingsDirectory)
    {
        _settingsDirectory = settingsDirectory;
        InitializeComponent();
        var saved = AppPreferencesStore.Load(settingsDirectory ?? StoreFiles.DefaultDirectory);
        _paperKey = saved.CreatePaper;
        CustomWidthLabel.Text = Loc.T("Width ({0})", Unit);
        CustomHeightLabel.Text = Loc.T("Height ({0})", Unit);
        System.Windows.Automation.AutomationProperties.SetName(CustomWidth, CustomWidthLabel.Text);
        System.Windows.Automation.AutomationProperties.SetName(CustomHeight, CustomHeightLabel.Text);
        CustomWidth.Text = Shown(saved.CreateWidth > 0 ? saved.CreateWidth : _metric ? 210 * PageEdits.PointsPerMillimetre : 612);
        CustomHeight.Text = Shown(saved.CreateHeight > 0 ? saved.CreateHeight : _metric ? 297 * PageEdits.PointsPerMillimetre : 792);
        PictureList.ItemsSource = _pictures;
        var installed = Fonts.SystemFontFamilies.SelectMany(f => f.FamilyNames.Values).ToHashSet(StringComparer.OrdinalIgnoreCase);
        FontBox.ItemsSource = new[] { "Arial", "Times New Roman", "Courier New", "Calibri", "Cambria", "Consolas", "Georgia", "Verdana", "Tahoma", "Segoe UI" }.Where(installed.Contains).ToList();
        FontBox.SelectedIndex = 0;
        _action = new ToolAction(Loc.T("Create"), "", CanRun, RunAsync);
        _ready = true;
        ShowSource();
    }

    public override ToolAction? Action => _action;

    internal string Unit => _metric ? "mm" : "in";

    internal double PointsPerUnit => _metric ? PageEdits.PointsPerMillimetre : 72;

    private string Shown(double points) => (points / PointsPerUnit).ToString("0.##", CultureInfo.CurrentCulture);

    private int Source => SourceBox.SelectedIndex;

    protected override void OnAttach()
    {
        PeekClipboard();
        Refresh();
    }

    private bool MakesPictures => Source == (int)CreateSource.Pictures || (Source == ClipboardIndex && _clipboard == ClipboardKind.Picture);

    private bool MakesText => Source == (int)CreateSource.Text || (Source == ClipboardIndex && _clipboard == ClipboardKind.Text);

    private bool TryBlankPages(out int pages) =>
        int.TryParse(BlankPagesBox.Text, out pages) && pages is >= 1 and <= PdfMaker.MostBlankPages;

    // The page sides the engine accepts, in points.
    private const double LeastSide = 3, MostSide = 14400;

    private static readonly (string Key, PdfPaper Paper)[] Papers =
    [
        ("A4", PdfPaper.A4), ("A3", PdfPaper.A3), ("A5", PdfPaper.A5), ("Letter", PdfPaper.Letter),
        ("Legal", PdfPaper.Legal), ("Custom", PdfPaper.Custom), ("Picture", PdfPaper.Picture),
    ];

    private static string NameOf(string key) => key switch
    {
        "Letter" => Loc.T("Letter"),
        "Legal" => Loc.T("Legal"),
        "Custom" => Loc.T("Custom size"),
        "Picture" => Loc.T("Size of the picture"),
        _ => key,
    };

    private string PickedKey => Papers.FirstOrDefault(p => NameOf(p.Key) == PaperBox.SelectedItem as string).Key ?? "A4";

    private bool CustomPicked => PickedKey == "Custom";

    // The custom size in points; null while it is not a number within what a page can be.
    private (double Width, double Height)? CustomPoints()
    {
        if (!double.TryParse(CustomWidth.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double width)
            || !double.TryParse(CustomHeight.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double height)) return null;
        width = Math.Round(width * PointsPerUnit, 3);
        height = Math.Round(height * PointsPerUnit, 3);
        return width is >= LeastSide and <= MostSide && height is >= LeastSide and <= MostSide ? (width, height) : null;
    }

    private void RememberPaper()
    {
        var size = CustomPoints();
        AppPreferencesStore.Update(p =>
        {
            p.CreatePaper = _paperKey;
            if (size is { } s) (p.CreateWidth, p.CreateHeight) = s;
        }, _settingsDirectory ?? StoreFiles.DefaultDirectory);
    }

    private string SizeLimits()
    {
        string least = (Math.Ceiling(LeastSide / PointsPerUnit * 100) / 100).ToString("0.##", CultureInfo.CurrentCulture);
        string most = Math.Round(MostSide / PointsPerUnit, 2).ToString("0.##", CultureInfo.CurrentCulture);
        return Loc.T("Type a size from {0} to {1} {2}.", least, most, Unit);
    }

    private bool CanRun() => Source switch
    {
        (int)CreateSource.Blank => TryBlankPages(out _) && CustomFits(),
        (int)CreateSource.Pictures => _pictures.Count > 0 && CustomFits(),
        (int)CreateSource.Text => (_longText is not null || TypedText.Text.Trim().Length > 0) && CustomFits(),
        (int)CreateSource.WebPage => _webPage is not null && CustomFits(),
        (int)CreateSource.Word => _wordPath is not null,
        _ => _clipboard != ClipboardKind.Nothing && CustomFits(),
    };

    private bool CustomFits() => !CustomPicked || CustomPoints() is not null;

    private string? Blocker() =>
        _fileProblem ?? (Source == (int)CreateSource.Blank && !TryBlankPages(out _) ? Loc.T("Type a number from 1 to {0}.", PdfMaker.MostBlankPages)
            : Source == (int)CreateSource.Word ? null
            : Source != ClipboardIndex || _clipboard != ClipboardKind.Nothing ? (CustomFits() ? null : SizeLimits())
            : null);

    private List<string> PaperNames() => [.. Papers.Where(p => p.Paper != PdfPaper.Picture || MakesPictures).Select(p => NameOf(p.Key))];

    private void PeekClipboard()
    {
        _clipboard = Source == ClipboardIndex ? ClipboardContent.Peek() : ClipboardKind.Nothing;
        ClipboardState.Text = _clipboard switch
        {
            ClipboardKind.Text => Loc.T("The clipboard holds text."),
            ClipboardKind.Picture => Loc.T("The clipboard holds a picture."),
            _ => Loc.T("Copy text or a picture, then come back."),
        };
    }

    private void ShowSource()
    {
        static Visibility When(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
        BlankOptions.Visibility = When(Source == (int)CreateSource.Blank);
        PictureOptions.Visibility = When(Source == (int)CreateSource.Pictures);
        TextOptions.Visibility = When(Source == (int)CreateSource.Text);
        WebPageOptions.Visibility = When(Source == (int)CreateSource.WebPage);
        WebPageName.Text = _webPage is null ? "" : System.IO.Path.GetFileName(_webPage);
        TypedText.Visibility = When(_longText is null);
        LongTextRow.Visibility = When(_longText is not null);
        WordOptions.Visibility = When(Source == (int)CreateSource.Word);
        WordState.Text = _wordPath is null ? Loc.T("Layout can differ from Word.") : System.IO.Path.GetFileName(_wordPath);
        ClipboardOptions.Visibility = When(Source == ClipboardIndex);
        SetupOptions.Visibility = When(Source == ClipboardIndex ? _clipboard != ClipboardKind.Nothing : Source != (int)CreateSource.Word);
        var names = PaperNames();
        if (PaperBox.ItemsSource is not List<string> shown || !shown.SequenceEqual(names))
        {
            _building = true;
            PaperBox.ItemsSource = names;
            PaperBox.SelectedIndex = Math.Max(names.IndexOf(NameOf(_paperKey)), 0);
            _building = false;
        }
        CustomSize.Visibility = When(CustomPicked);
        OrientationBox.IsEnabled = PickedKey != "Picture";
        MarginRow.Visibility = When(Source != (int)CreateSource.Blank);
        FontRow.Visibility = When(MakesText);
        string? blocker = Blocker();
        Reason.Text = blocker ?? "";
        ReasonRow.Visibility = When(blocker is not null);
        UpdateMoveButtons();
    }

    private void Refresh()
    {
        ShowSource();
        RaiseActionChanged();
    }

    // The engine turns a custom size to portrait under Auto, so a wide size typed for a page of text is sent as landscape.
    private PdfPageSetup Setup(bool pictures = false)
    {
        var (width, height) = CustomPoints() ?? (595.276, 841.89);
        var orientation = OrientationBox.SelectedIndex switch { 1 => PdfOrientation.Portrait, 2 => PdfOrientation.Landscape, _ => PdfOrientation.Auto };
        if (orientation == PdfOrientation.Auto && CustomPicked && !pictures) orientation = width > height ? PdfOrientation.Landscape : PdfOrientation.Portrait;
        return new(
            Papers.First(p => p.Key == PickedKey).Paper,
            orientation,
            Source == (int)CreateSource.Blank ? 36 : Tagged(MarginBox),
            width, height);
    }

    private string Family => FontBox.SelectedItem as string ?? "Arial";

    private static int Tagged(ComboBox box) => int.Parse((string)((ComboBoxItem)box.SelectedItem).Tag);

    /// <summary>What the panel is set to make; null when the clipboard emptied since it was looked at.</summary>
    public CreateRequest? Request()
    {
        var setup = Setup();
        RememberPaper();
        switch (Source)
        {
            case (int)CreateSource.Blank:
                TryBlankPages(out int pages);
                return new(CreateSource.Blank, setup, Loc.T("Blank.pdf"), pages);
            case (int)CreateSource.Pictures:
                return new(CreateSource.Pictures, Setup(pictures: true), PicturesTitle(), Files: [.. _pictures.Select(p => p.Path)]);
            case (int)CreateSource.Text:
                return new(CreateSource.Text, setup, Loc.T("Text.pdf"), Text: _longText ?? TypedText.Text, FontSize: Tagged(FontSizeBox), Family: Family);
            case (int)CreateSource.WebPage:
                return new(CreateSource.WebPage, setup, System.IO.Path.GetFileNameWithoutExtension(_webPage!) + ".pdf", Files: [_webPage!]);
            case (int)CreateSource.Word:
                return new(CreateSource.Word, setup, System.IO.Path.GetFileNameWithoutExtension(_wordPath!) + ".pdf", Files: [_wordPath!]);
        }
        var content = ClipboardContent.Read();
        if (content.Text is { } text) return new(CreateSource.Text, setup, Loc.T("Clipboard.pdf"), Text: text, FontSize: Tagged(FontSizeBox), Family: Family);
        if (content.Picture is { } picture) return new(CreateSource.Pictures, Setup(pictures: true), Loc.T("Clipboard.pdf"), Picture: picture);
        PeekClipboard();
        Refresh();
        return null;
    }

    public Task CreateAsync(IToolHost host, CreateRequest request) => CreateJob.RunAsync(host, _codec, _fonts, request);

    private string PicturesTitle() => _pictures.Count == 1 ? System.IO.Path.GetFileNameWithoutExtension(_pictures[0].Path) + ".pdf" : Loc.T("Pictures.pdf");

    private async Task RunAsync()
    {
        if (Request() is not { } request)
        {
            Host!.ShowProblem(new Problem(Loc.T("Clipboard is empty"), Loc.T("Copy text or a picture, then try again.")));
            return;
        }
        await CreateAsync(Host!, request);
    }

    private void CreatePanel_Loaded(object sender, RoutedEventArgs e)
    {
        _owner = Window.GetWindow(this);
        if (_owner is not null) _owner.Activated += Window_Activated;
    }

    private void CreatePanel_Unloaded(object sender, RoutedEventArgs e)
    {
        if (_owner is not null) _owner.Activated -= Window_Activated;
        _owner = null;
    }

    private void Window_Activated(object? sender, EventArgs e)
    {
        if (Source != ClipboardIndex) return;
        PeekClipboard();
        Refresh();
    }

    private void SourceBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _fileProblem = null;
        _longText = null;
        PeekClipboard();
        Refresh();
    }

    private void PaperBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || _building) return;
        _paperKey = PickedKey;
        Refresh();
    }

    private void CustomSize_LostFocus(object sender, RoutedEventArgs e) => RememberPaper();

    private void Input_Changed(object sender, TextChangedEventArgs e)
    {
        if (!_ready) return;
        _fileProblem = null;
        Refresh();
    }

    private void AddPictures_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = Loc.T("Pictures") + "|" + string.Join(';', PdfMaker.PictureExtensions.Select(x => "*" + x)),
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        foreach (string file in dialog.FileNames) _pictures.Add(new PictureItem(file));
        Refresh();
    }

    private void ChooseWebPage_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("Web pages") + "|" + string.Join(';', WebPageRules.Extensions.Select(x => "*" + x)) };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        _webPage = dialog.FileName;
        Refresh();
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        if (paths.FirstOrDefault(WebPageRules.IsWebPage) is { } page)
        {
            _webPage = page;
            if (Source != (int)CreateSource.WebPage) SourceBox.SelectedIndex = (int)CreateSource.WebPage;
            Refresh();
            return;
        }
        var pictures = paths.Where(p => PdfMaker.PictureExtensions.Contains(System.IO.Path.GetExtension(p), StringComparer.OrdinalIgnoreCase)).ToList();
        if (pictures.Count == 0)
        {
            Host?.SetStatus(Loc.T("Only picture files can be added."));
            return;
        }
        if (Source != (int)CreateSource.Pictures) SourceBox.SelectedIndex = (int)CreateSource.Pictures;
        foreach (string file in pictures) _pictures.Add(new PictureItem(file));
        Refresh();
    }

    private void PictureList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateMoveButtons();

    private void UpdateMoveButtons()
    {
        int at = PictureList.SelectedIndex;
        MoveUp.IsEnabled = at > 0;
        MoveDown.IsEnabled = at >= 0 && at < _pictures.Count - 1;
        RemovePicture.IsEnabled = at >= 0;
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => Move(-1);

    private void MoveDown_Click(object sender, RoutedEventArgs e) => Move(1);

    private void Move(int step)
    {
        int at = PictureList.SelectedIndex, to = at + step;
        if (at < 0 || to < 0 || to >= _pictures.Count) return;
        _pictures.Move(at, to);
        PictureList.SelectedIndex = to;
        UpdateMoveButtons();
    }

    private void RemovePicture_Click(object sender, RoutedEventArgs e)
    {
        int at = PictureList.SelectedIndex;
        _pictures.RemoveAt(at);
        PictureList.SelectedIndex = Math.Min(at, _pictures.Count - 1);
        Refresh();
    }

    private void ChooseWord_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("Word files") + "|*.docx" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        UseWordFile(dialog.FileName);
    }

    internal void UseWordFile(string path)
    {
        _wordPath = path;
        Refresh();
    }

    private async void OpenTextFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = TextFiles.Filter };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) await LoadTextFileAsync(dialog.FileName);
    }

    internal async Task LoadTextFileAsync(string path)
    {
        try
        {
            long size = new FileInfo(path).Length;
            if (size > TextFiles.MostFileBytes)
            {
                _fileProblem = Loc.T("That file is too big. Pick a text file under 20 MB.");
            }
            else if (size > TextFiles.MostBytes)
            {
                string text = await Task.Run(() => TextFiles.Decode(File.ReadAllBytes(path)));
                _fileProblem = null;
                _longText = text;
                LongTextNote.Text = Loc.T("Using {0} ({1} MB). It is too long to show here.", System.IO.Path.GetFileName(path), (size / (double)(1 << 20)).ToString("0.#"));
            }
            else
            {
                _fileProblem = null;
                _longText = null;
                TypedText.Text = TextFiles.Decode(File.ReadAllBytes(path));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _fileProblem = Loc.T("That file could not be read. Check that no other program has it open.");
        }
        Refresh();
    }

    private void UseTypedText_Click(object sender, RoutedEventArgs e)
    {
        _longText = null;
        Refresh();
    }
}
