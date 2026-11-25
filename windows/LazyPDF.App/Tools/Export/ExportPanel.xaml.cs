using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Export;

/// <summary>Saves the document, or some of its pages, as Word, Excel, PowerPoint, HTML, Markdown, RTF, text or pictures.</summary>
public partial class ExportPanel : ToolPanel
{
    private readonly IImageCodec _codec = new WicImageCodec();
    private readonly ToolAction _action;
    private readonly bool _ready;

    public ExportPanel()
    {
        InitializeComponent();
        NameBox.Text = Loc.T("{name} page {n}");
        NameHint.Text = Loc.T("Use {0} and {1}. A name that is taken gets a number.", "{name}", "{n}");
        _action = new ToolAction(Loc.T("Export"), "", CanRun, RunAsync);
        _ready = true;
    }

    public override ToolAction? Action => _action;

    private ExportFormat Format => Enum.Parse<ExportFormat>((string)((ComboBoxItem)FormatBox.SelectedItem).Tag);

    private PictureFormat Picture => PictureTypeBox.SelectedIndex switch
    {
        1 => PictureFormat.Jpeg,
        2 => PictureFormat.Tiff,
        3 => PictureFormat.Bmp,
        _ => PictureFormat.Png,
    };

    private PictureColour Colour => (PictureColour)ColourBox.SelectedIndex;

    private PageScope Scope => TypedPages.IsChecked == true ? PageScope.Typed : CurrentPage.IsChecked == true ? PageScope.Current : PageScope.All;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Refresh();
    }

    protected override void OnDetach() => Tab!.Changed -= Tab_Changed;

    private void Tab_Changed(object? sender, EventArgs e) => Refresh();

    private ExportPages Pages() => ExportPages.Of(Scope, PagesBox.Text, Viewer?.PageIndex ?? 0, Tab?.PageCount ?? 0);

    private string? Blocker()
    {
        if (Tab is not { } tab) return null;
        if (!Exporter.Allowed(tab.Document)) return Loc.T("This file does not allow copying its content.");
        if (Format == ExportFormat.Pictures && !tab.CanDraw) return Loc.T("Windows cannot draw this file.");
        var pages = Pages();
        if (pages.Error is not null) return pages.Error;
        return Format == ExportFormat.Pictures ? ExportNames.Error(NameBox.Text, pages.Pages?.Count ?? tab.PageCount) : null;
    }

    private bool CanRun() => Tab is not null && Blocker() is null;

    private void Refresh()
    {
        var format = Format;
        HtmlOptions.Visibility = format == ExportFormat.Html ? Visibility.Visible : Visibility.Collapsed;
        MarkdownPicturesBox.Visibility = format == ExportFormat.Markdown ? Visibility.Visible : Visibility.Collapsed;
        PictureOptions.Visibility = format == ExportFormat.Pictures ? Visibility.Visible : Visibility.Collapsed;
        var picture = Picture;
        BlackWhiteItem.IsEnabled = Exporter.Allows(picture, PictureColour.BlackWhite);
        if (!BlackWhiteItem.IsEnabled && Colour == PictureColour.BlackWhite) ColourBox.SelectedIndex = (int)PictureColour.Grayscale;
        QualityRow.Visibility = picture == PictureFormat.Jpeg ? Visibility.Visible : Visibility.Collapsed;
        SizeHint.Visibility = picture is PictureFormat.Tiff or PictureFormat.Bmp ? Visibility.Visible : Visibility.Collapsed;

        string? blocker = Blocker();
        Reason.Text = blocker ?? "";
        ReasonRow.Visibility = blocker is null ? Visibility.Collapsed : Visibility.Visible;
        RaiseActionChanged();
    }

    private ExportOptions Options(IReadOnlyList<int>? pages) => new(
        Format,
        pages,
        FixedHtml: HtmlLayoutBox.SelectedIndex == 1,
        MarkdownPictures: MarkdownPicturesBox.IsChecked == true,
        Picture: Picture,
        Dpi: int.Parse((string)((ComboBoxItem)DpiBox.SelectedItem).Tag),
        Quality: (int)QualityBox.Value,
        NamePattern: NameBox.Text,
        Replace: ReplaceBox.IsChecked == true,
        Colour: Colour);

    private async Task RunAsync()
    {
        var tab = Tab!;
        var host = Host!;
        var options = Options(Pages().Pages);
        string? target = options.ToFolder ? ChooseFolder() : ChooseFile(tab.Path, Path.GetFileNameWithoutExtension(tab.Title), options.Extension);
        if (target is not null) await ExportJob.RunAsync(tab, host, _codec, options, target);
    }

    private string? ChooseFile(string? source, string stem, string extension)
    {
        var dialog = new SaveFileDialog
        {
            FileName = stem + extension,
            DefaultExt = extension,
            Filter = $"{((ComboBoxItem)FormatBox.SelectedItem).Content}|*{extension}",
        };
        if (source is not null) dialog.InitialDirectory = Path.GetDirectoryName(source);
        return dialog.ShowDialog(Window.GetWindow(this)) == true ? dialog.FileName : null;
    }

    private string? ChooseFolder()
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Choose a folder for the pictures") };
        return dialog.ShowDialog(Window.GetWindow(this)) == true ? dialog.FolderName : null;
    }

    private void FormatBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready) Refresh();
    }

    private void PictureTypeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready) Refresh();
    }

    private void ColourBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready) Refresh();
    }

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready) Refresh();
    }

    private void Scope_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        if (TypedPages.IsChecked == true) PagesBox.Focus();
        Refresh();
    }

    private void PagesBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready) Refresh();
    }
}
