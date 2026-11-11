using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
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

    private const int ClipboardIndex = 3;

    private readonly IImageCodec _codec = new WicImageCodec();
    private readonly IFontSource _fonts = new SystemFontSource();
    private readonly ObservableCollection<PictureItem> _pictures = [];
    private readonly ToolAction _action;
    private readonly bool _ready;
    private ClipboardKind _clipboard;
    private string? _fileProblem;
    private Window? _owner;

    public CreatePanel()
    {
        InitializeComponent();
        PictureList.ItemsSource = _pictures;
        var installed = Fonts.SystemFontFamilies.SelectMany(f => f.FamilyNames.Values).ToHashSet(StringComparer.OrdinalIgnoreCase);
        FontBox.ItemsSource = new[] { "Arial", "Times New Roman", "Courier New", "Calibri", "Cambria", "Consolas", "Georgia", "Verdana", "Tahoma", "Segoe UI" }.Where(installed.Contains).ToList();
        FontBox.SelectedIndex = 0;
        _action = new ToolAction(Loc.T("Create"), "", CanRun, RunAsync);
        _ready = true;
        ShowSource();
    }

    public override ToolAction? Action => _action;

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

    private bool CanRun() => Source switch
    {
        (int)CreateSource.Blank => TryBlankPages(out _),
        (int)CreateSource.Pictures => _pictures.Count > 0,
        (int)CreateSource.Text => TypedText.Text.Trim().Length > 0,
        _ => _clipboard != ClipboardKind.Nothing,
    };

    private string? Blocker() =>
        _fileProblem ?? (Source == (int)CreateSource.Blank && !TryBlankPages(out _)
            ? Loc.T("Type a number from 1 to {0}.", PdfMaker.MostBlankPages)
            : null);

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
        ClipboardOptions.Visibility = When(Source == ClipboardIndex);
        SetupOptions.Visibility = When(Source != ClipboardIndex || _clipboard != ClipboardKind.Nothing);
        PicturePaper.Visibility = When(MakesPictures);
        if (!MakesPictures && PaperBox.SelectedItem == PicturePaper) PaperBox.SelectedIndex = 0;
        OrientationBox.IsEnabled = PaperBox.SelectedItem != PicturePaper;
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

    private PdfPageSetup Setup() => new(
        PaperBox.SelectedIndex switch { 1 => PdfPaper.Letter, 2 => PdfPaper.Picture, _ => PdfPaper.A4 },
        OrientationBox.SelectedIndex switch { 1 => PdfOrientation.Portrait, 2 => PdfOrientation.Landscape, _ => PdfOrientation.Auto },
        Source == (int)CreateSource.Blank ? 36 : Tagged(MarginBox));

    private string Family => FontBox.SelectedItem as string ?? "Arial";

    private static int Tagged(ComboBox box) => int.Parse((string)((ComboBoxItem)box.SelectedItem).Tag);

    /// <summary>What the panel is set to make; null when the clipboard emptied since it was looked at.</summary>
    public CreateRequest? Request()
    {
        var setup = Setup();
        switch (Source)
        {
            case (int)CreateSource.Blank:
                TryBlankPages(out int pages);
                return new(CreateSource.Blank, setup, Loc.T("Blank.pdf"), pages);
            case (int)CreateSource.Pictures:
                return new(CreateSource.Pictures, setup, PicturesTitle(), Files: [.. _pictures.Select(p => p.Path)]);
            case (int)CreateSource.Text:
                return new(CreateSource.Text, setup, Loc.T("Text.pdf"), Text: TypedText.Text, FontSize: Tagged(FontSizeBox), Family: Family);
        }
        var content = ClipboardContent.Read();
        if (content.Text is { } text) return new(CreateSource.Text, setup, Loc.T("Clipboard.pdf"), Text: text, FontSize: Tagged(FontSizeBox), Family: Family);
        if (content.Picture is { } picture) return new(CreateSource.Pictures, setup, Loc.T("Clipboard.pdf"), Picture: picture);
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
        PeekClipboard();
        Refresh();
    }

    private void PaperBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready) Refresh();
    }

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

    private void OpenTextFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("Text files") + "|*.txt" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            if (new FileInfo(dialog.FileName).Length > TextFiles.MostBytes)
            {
                _fileProblem = Loc.T("That file is too big. Pick a text file under 1 MB.");
            }
            else
            {
                _fileProblem = null;
                TypedText.Text = TextFiles.Decode(File.ReadAllBytes(dialog.FileName));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _fileProblem = Loc.T("That file could not be read. Check that no other program has it open.");
        }
        Refresh();
    }
}
