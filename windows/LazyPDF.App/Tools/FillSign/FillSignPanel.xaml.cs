using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.FillSign;

/// <summary>A saved signature in the list.</summary>
internal sealed record SavedRow(SavedItem Item, BitmapSource Picture)
{
    public string Name => Item.Kind switch
    {
        SavedKind.Initials => Loc.T("Saved initials"),
        SavedKind.Stamp => Loc.T("Stamp"),
        _ => Loc.T("Saved signature"),
    };
}

internal sealed record DateChoice(string Pattern, string Sample);
internal sealed record ColourChoice(string Name, double[] Rgb);
internal sealed record ShapeChoice(string Name, MarkShape Shape);

/// <summary>Signature, initials, a line of text, today's date or a mark, put on the page where the pointer says.</summary>
public partial class FillSignPanel : ToolPanel
{
    private static readonly int[] Sizes = [10, 12, 14, 18, 24, 36];
    private static readonly string[] DatePatterns = ["d MMMM yyyy", "dd.MM.yyyy", "yyyy-MM-dd", "M/d/yyyy"];

    private readonly SavedSignatures _saved;
    private readonly SystemFontSource _fonts = new();
    private PdfRgbaImage? _image;
    private PlacementTool? _tool;
    private bool _cautioned;
    private bool _loading;

    public FillSignPanel()
        : this(SavedSignatures.DefaultDirectory)
    {
    }

    internal FillSignPanel(string savedDirectory)
    {
        _saved = new SavedSignatures(savedDirectory);
        InitializeComponent();
        SizeBox.ItemsSource = Sizes;
        SizeBox.SelectedItem = 12;
        ColourBox.ItemsSource = new ColourChoice[]
        {
            new(Loc.T("Black"), [0, 0, 0]),
            new(Loc.T("Blue"), [0.1, 0.3, 0.8]),
            new(Loc.T("Red"), [0.8, 0.1, 0.1]),
            new(Loc.T("Green"), [0.1, 0.55, 0.25]),
        };
        ColourBox.SelectedIndex = 0;
        ShapeBox.ItemsSource = new ShapeChoice[]
        {
            new(Loc.T("Check mark"), MarkShape.Check),
            new(Loc.T("Cross"), MarkShape.Cross),
            new(Loc.T("Dot"), MarkShape.Dot),
            new(Loc.T("Line"), MarkShape.Line),
        };
        ShapeBox.SelectedIndex = 0;
        var today = DateTime.Today;
        FormatBox.ItemsSource = DatePatterns.Select(p => new DateChoice(p, today.ToString(p, CultureInfo.CurrentCulture))).ToList();
        FormatBox.SelectedIndex = 0;
        ShowKind();
    }

    public override ToolAction? Action => new(_tool is null ? Loc.T("Place on page") : Loc.T("Stop placing"), "\uE710", () => _tool is not null || Ready, Arm);

    private bool Images => SignatureKind.IsChecked == true || InitialsKind.IsChecked == true;

    private bool Line => MarkKind.IsChecked == true && ((ShapeChoice)ShapeBox.SelectedItem).Shape == MarkShape.Line;

    private SavedKind Kind => InitialsKind.IsChecked == true ? SavedKind.Initials : SavedKind.Signature;

    private bool Ready => Images ? _image is not null : TextKind.IsChecked != true || WordsBox.Text.Trim().Length > 0;

    protected override void OnAttach() => _cautioned = false;

    protected override void OnDetach() => Stop();

    private void ShowKind()
    {
        if (!IsInitialized) return;
        Stop();
        ImagePage.Visibility = Images ? Visibility.Visible : Visibility.Collapsed;
        TextPage.Visibility = Images ? Visibility.Collapsed : Visibility.Visible;
        WordsPage.Visibility = TextKind.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        FormatPage.Visibility = DateKind.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ShapePage.Visibility = MarkKind.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        _image = null;
        if (Images) FillSaved();
        RaiseActionChanged();
    }

    private void FillSaved(string? keepPath = null)
    {
        var rows = new List<SavedRow>();
        foreach (var item in _saved.List(Kind))
        {
            if (_saved.Load(item) is { } image) rows.Add(new SavedRow(item, SignatureArt.ToBitmap(image)));
        }
        _loading = true;
        SavedList.ItemsSource = rows;
        _loading = false;
        NoneSaved.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SavedList.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (keepPath is null)
        {
            if (rows.Count > 0) SavedList.SelectedIndex = 0;
            return;
        }
        if (keepPath.Length == 0) return; // nothing was selected, so a drawn signature stays
        int kept = rows.FindIndex(r => r.Item.Path == keepPath);
        if (kept >= 0)
        {
            _loading = true;
            SavedList.SelectedIndex = kept;
            _loading = false;
            return;
        }
        _image = null;
        Stop();
    }

    private Task Arm()
    {
        if (_tool is not null)
        {
            Stop();
            return Task.CompletedTask;
        }
        var document = Tab!.Document;
        if (FillSignPlacement.Refusal(document) is { } problem)
        {
            Host!.ShowProblem(problem);
        }
        else if (!_cautioned && FillSignPlacement.Caution(document) is { } caution)
        {
            Host!.ShowNotice(Loc.T("Check before going on"), caution, new NoticeAction(Loc.T("Go on anyway"), GoOn));
        }
        else
        {
            Begin();
        }
        return Task.CompletedTask;
    }

    private void GoOn()
    {
        if (Tab is null) return;
        _cautioned = true;
        Begin();
    }

    private void Begin()
    {
        double aspect = Images ? _image!.Width / (double)_image.Height : 0;
        bool mark = MarkKind.IsChecked == true;
        _tool = new PlacementTool(Viewer!, mark && !Line ? 1 : aspect, Placed, Stop, Line);
        Viewer!.PointerTool = _tool;
        Hint.Visibility = Visibility.Visible;
        string click = mark ? $"{Loc.T("Click the page where it goes.")} {Loc.T("It is placed as a mark you can move with Comment.")}"
            : aspect > 0 ? Loc.T("Click the page, or drag a box, to place it.") : Loc.T("Click the page where the text starts.");
        HintText.Text = $"{click} {Loc.T("Or press Enter on the page.")}";
        Host!.SetStatus(Loc.T("Click where it should go."));
        RaiseActionChanged();
    }

    private void Stop()
    {
        if (_tool is null) return;
        var tool = _tool;
        _tool = null;
        if (ReferenceEquals(Viewer?.PointerTool, tool)) Viewer!.PointerTool = null;
        Hint.Visibility = Visibility.Collapsed;
        RaiseActionChanged();
    }

    private void Placed(int page, Point from, Point? to)
    {
        var tab = Tab;
        Stop();
        if (tab is null) return;
        try
        {
            var now = DateTimeOffset.Now;
            if (Images) PlaceImage(tab, page, from, to, now);
            else if (MarkKind.IsChecked == true) FillSignPlacement.PlaceMark(tab, page, ((ShapeChoice)ShapeBox.SelectedItem).Shape, from, to, (int)SizeBox.SelectedItem, ((ColourChoice)ColourBox.SelectedItem).Rgb, now);
            else FillSignPlacement.PlaceText(tab, _fonts, page, from, TextToPlace(now), (int)SizeBox.SelectedItem, ((ColourChoice)ColourBox.SelectedItem).Rgb, now);
        }
        catch (InvalidOperationException error)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Text cannot be drawn"), error.Message == AnnotationText.NoFont ? error.Message : Loc.T("Choose another font or shorter text.")));
            return;
        }
        catch (ArgumentException)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Nothing to place"), Loc.T("There is no text or picture to place.")));
            return;
        }
        catch (PdfReadException)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Change not kept"), Loc.T("The file would not read back with that change. Save a copy and try again.")));
            return;
        }
        if (KeepPlacing.IsChecked == true)
        {
            Begin();
            Host!.SetStatus(Loc.T("Placed on page {0}. Click for the next one.", page + 1));
            return;
        }
        Host!.SetStatus(Loc.T("Placed on page {0}.", page + 1));
    }

    private void PlaceImage(DocumentTab tab, int page, Point from, Point? to, DateTimeOffset now)
    {
        var image = _image!;
        double aspect = image.Width / (double)image.Height;
        var size = Viewer!.PageSize(page);
        var box = to is { } end && FillSignPlacement.FromDrag(from, end, aspect, size) is { Width: >= 20 } dragged
            ? dragged
            : FillSignPlacement.Around(from, InitialsKind.IsChecked == true ? FillSignPlacement.InitialsWidth : FillSignPlacement.SignatureWidth, aspect, size);
        FillSignPlacement.PlaceImage(tab, page, box, image, now);
    }

    private string TextToPlace(DateTimeOffset now) =>
        DateKind.IsChecked == true ? now.ToString(((DateChoice)FormatBox.SelectedItem).Pattern, CultureInfo.CurrentCulture) : WordsBox.Text.Trim();

    private void Kind_Checked(object sender, RoutedEventArgs e) => ShowKind();

    private void Shape_Changed(object sender, SelectionChangedEventArgs e) => Stop();

    private void WordsBox_TextChanged(object sender, TextChangedEventArgs e) => RaiseActionChanged();

    private void SavedList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        _image = SavedList.SelectedItem is SavedRow row ? _saved.Load(row.Item) : null;
        Stop();
        RaiseActionChanged();
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not SavedRow row) return;
        if (Host is null) return;
        var title = row.Item.Kind == SavedKind.Initials ? Loc.T("Delete these initials?") : Loc.T("Delete this signature?");
        Host.ShowNotice(title, Loc.T("A saved copy cannot be brought back."), new NoticeAction(Loc.T("Delete"), () =>
        {
            if (Tab is null) return;
            _saved.Remove(row.Item);
            FillSaved((SavedList.SelectedItem as SavedRow)?.Item.Path ?? "");
            RaiseActionChanged();
        }));
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        Stop();
        Maker.Reset();
        ChoosePage.Visibility = Visibility.Collapsed;
        Maker.Visibility = Visibility.Visible;
    }

    private void Maker_Made(object? sender, EventArgs e)
    {
        var image = Maker.Image!;
        Maker.Visibility = Visibility.Collapsed;
        ChoosePage.Visibility = Visibility.Visible;
        if (Maker.Keep)
        {
            var item = _saved.Add(Kind, image);
            FillSaved();
            SavedList.SelectedIndex = ((List<SavedRow>)SavedList.ItemsSource).FindIndex(r => r.Item == item);
        }
        else
        {
            SavedList.SelectedIndex = -1;
        }
        _image = image;
        RaiseActionChanged();
    }

    private void Maker_Cancelled(object? sender, EventArgs e)
    {
        Maker.Visibility = Visibility.Collapsed;
        ChoosePage.Visibility = Visibility.Visible;
    }
}
