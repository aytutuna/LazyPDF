using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tools.Comment;

/// <summary>Marks on the pages: text markup from a selection, shapes and notes drawn with the pointer, and the look they get.</summary>
public partial class CommentPanel : ToolPanel
{
    private static readonly (string Name, double[]? Rgb)[] Colours =
    [
        (Loc.T("Automatic"), null), (Loc.T("Yellow"), [1, 0.92, 0.2]), (Loc.T("Orange"), [1, 0.6, 0.1]), (Loc.T("Red"), [0.9, 0.15, 0.15]),
        (Loc.T("Green"), [0.2, 0.7, 0.3]), (Loc.T("Blue"), [0.15, 0.4, 0.9]), (Loc.T("Purple"), [0.6, 0.3, 0.8]), (Loc.T("Black"), [0, 0, 0]),
    ];

    private static readonly (string Name, double[]? Rgb)[] Fills =
    [
        (Loc.T("None"), null), .. Colours[1..7], (Loc.T("White"), [1, 1, 1]), Colours[7],
    ];

    private static readonly (string Name, LineEnding Value)[] Heads =
    [
        (Loc.T("Open arrow"), LineEnding.OpenArrow), (Loc.T("Closed arrow"), LineEnding.ClosedArrow), (Loc.T("Circle"), LineEnding.Circle),
        (Loc.T("Square"), LineEnding.Square), (Loc.T("Diamond"), LineEnding.Diamond), (Loc.T("Slash"), LineEnding.Slash), (Loc.T("None"), LineEnding.None),
    ];

    private static readonly (string Name, string Value)[] Icons =
    [
        (Loc.T("Note"), "Note"), (Loc.T("Comment"), "Comment"), (Loc.T("Help"), "Help"), (Loc.T("Key"), "Key"),
        (Loc.T("Paragraph"), "Paragraph"), (Loc.T("Insert"), "Insert"), (Loc.T("New paragraph"), "NewParagraph"),
    ];

    private static readonly (MarkTool Tool, string Text, string Glyph, string Hint)[] Tools =
    [
        (MarkTool.SelectText, Loc.T("Select text"), "\uE8E4", Loc.T("Select text, then pick a markup above.")),
        (MarkTool.Edit, Loc.T("Move marks"), "\uE8B0", Loc.T("Click a mark to move, resize or delete it.")),
        (MarkTool.Note, Loc.T("Note"), "\uE8BD", Loc.T("Click where the note goes.")),
        (MarkTool.TextBox, Loc.T("Text box"), "\uE8D2", Loc.T("Drag a box, then type.")),
        (MarkTool.Callout, Loc.T("Callout"), "\uE8F2", Loc.T("Drag from the spot to where the text goes.")),
        (MarkTool.Line, Loc.T("Line"), "\uE738", Loc.T("Drag to draw a line.")),
        (MarkTool.Arrow, Loc.T("Arrow"), "\uE72A", Loc.T("Drag to draw an arrow.")),
        (MarkTool.Rectangle, Loc.T("Rectangle"), "\uE739", Loc.T("Drag to draw a rectangle.")),
        (MarkTool.Oval, Loc.T("Oval"), "\uEA3A", Loc.T("Drag to draw an oval.")),
        (MarkTool.Polygon, Loc.T("Polygon"), "\uEB3C", Loc.T("Click each corner, double-click to finish.")),
        (MarkTool.Cloud, Loc.T("Cloud"), "\uE753", Loc.T("Click each corner, double-click to finish.")),
        (MarkTool.Pencil, Loc.T("Pencil"), "\uEDFB", Loc.T("Drag to draw freehand.")),
        (MarkTool.Eraser, Loc.T("Eraser"), "\uE75C", Loc.T("Drag over a drawing to erase it.")),
        (MarkTool.Stamp, Loc.T("Stamp"), "\uE8E1", Loc.T("Click where the stamp goes.")),
        (MarkTool.Attach, Loc.T("Attach file"), "\uE723", Loc.T("Click where the file goes.")),
    ];

    private static readonly Lazy<string[]> Families = new(() =>
    {
        string[] first = ["Helvetica", "Times New Roman", "Courier New"];
        var installed = Fonts.SystemFontFamilies
            .Where(f => !f.Source.StartsWith('@') && !first.Contains(f.Source) && !f.GetTypefaces().Any(t => t.TryGetGlyphTypeface(out var g) && g.Symbol))
            .Select(f => f.Source)
            .ToList();
        installed.Sort(string.Compare);
        return [.. first, .. installed];
    });

    private readonly SystemFontSource _fonts = new();
    private readonly SavedSignatures _pictures = new(SavedSignatures.StampsDirectory);
    private PdfRgbaImage? _picture;
    private readonly DispatcherTimer _settle = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly HashSet<object> _unsettled = [];
    private readonly Dictionary<MarkTool, RadioButton> _buttons = [];
    private EditTool? _edit;
    private SelectionBar? _bar;
    private IPagePointerTool? _active;
    private TextEditor? _editor;
    private ToolAction? _action;
    private MarkTool _tool = MarkTool.SelectText;
    private double[]? _color;
    private MarkStyle? _drawing;
    private bool _loading = true;
    private bool _choosing;
    private bool _allowed = true;
    private int _flattenable;

    public CommentPanel()
    {
        InitializeComponent();
        foreach (var (name, rgb) in Colours)
        {
            var swatch = new RadioButton
            {
                Style = (Style)FindResource("SwatchStyle"),
                GroupName = "Colour",
                Tag = rgb is null ? "auto" : rgb,
                Background = rgb is null ? Brushes.Transparent : new SolidColorBrush(Color.FromRgb(Channel(rgb[0]), Channel(rgb[1]), Channel(rgb[2]))),
                IsChecked = rgb is null,
                ToolTip = name,
            };
            AutomationProperties.SetName(swatch, name);
            // Click as well, as clicking the swatch that is already checked raises no Checked.
            swatch.Checked += Swatch_Checked;
            swatch.Click += Swatch_Checked;
            Swatches.Children.Add(swatch);
        }
        foreach (var (tool, text, glyph, _) in Tools)
        {
            var button = new RadioButton { Style = (Style)FindResource("SegmentedItemStyle"), GroupName = "Tool", Content = text, Tag = tool, IsChecked = tool == _tool, Margin = new Thickness(0, 0, 0, 2) };
            LazyPDF.App.Icon.SetGlyph(button, glyph);
            AutomationProperties.SetName(button, text);
            button.Checked += Tool_Checked;
            _buttons[tool] = button;
            Palette.Children.Add(button);
        }
        foreach (var (glyph, button) in new[] { ("\uE7E6", MarkHighlight), ("\uE8DC", MarkUnderline), ("\uEDE0", MarkStrikeOut), ("\uED63", MarkSquiggly) })
        {
            LazyPDF.App.Icon.SetGlyph(button, glyph);
        }
        LazyPDF.App.Icon.SetGlyph(EditText, "\uE70F");
        LazyPDF.App.Icon.SetGlyph(DeleteMark, "\uE74D");
        LazyPDF.App.Icon.SetGlyph(ImportButton, "\uE896");
        LazyPDF.App.Icon.SetGlyph(ExportButton, "\uE898");
        FillBox.ItemsSource = Fills.Select(f => f.Name).ToList();
        FillBox.SelectedIndex = 0;
        LineStyleBox.ItemsSource = new[] { Loc.T("Solid"), Loc.T("Dashed"), Loc.T("Dotted") };
        LineStyleBox.SelectedIndex = 0;
        HeadBox.ItemsSource = Heads.Select(h => h.Name).ToList();
        HeadBox.SelectedIndex = 0;
        IconBox.ItemsSource = Icons.Select(i => i.Name).ToList();
        IconBox.SelectedIndex = 0;
        FontFamilyBox.ItemsSource = Families.Value;
        FontFamilyBox.SelectedIndex = 0;
        FontSizeBox.ItemsSource = new[] { 8, 10, 12, 14, 18, 24, 36 };
        FontSizeBox.Text = "12";
        StampName.ItemsSource = AnnotationText.StandardStamps.Select(AnnotationText.StampLabel).ToList();
        StampName.SelectedIndex = 0;
        FillPictures();
        StampDate.Content = Loc.T("Add today's date");
        AutomationProperties.SetName(StampDate, Loc.T("Add today's date"));
        _settle.Tick += Settle_Tick;
        _loading = false;
        ShowReadouts();
    }

    public override ToolAction? Action => _action ??= new ToolAction(Loc.T("Flatten comments"), "\uE81E", () => _allowed && !MarkWork.Running && _flattenable > 0, FlattenAsync);

    protected override void OnAttach()
    {
        _edit = new EditTool(Viewer!, () => NewMarker(Tab!));
        _edit.SelectionChanged += Edit_SelectionChanged;
        _edit.Moved += Edit_Moved;
        _edit.Resized += Edit_Resized;
        _edit.VertexMoved += Edit_VertexMoved;
        _edit.EditRequested += Edit_EditRequested;
        _bar = new SelectionBar(Viewer, () => _tool == MarkTool.SelectText && _allowed, MarkSelection);
        Tab!.Changed += Tab_Changed;
        _allowed = Exchange.CanComment(Tab.Document);
        if (!_allowed) Pick(MarkTool.SelectText);
        else if (MarkWork.Caution(Tab.Document) is { } caution) Host!.ShowNotice(Loc.T("File is signed"), caution);
        UpdateEnabled();
        Viewer!.ModeChanged += Viewer_ModeChanged;
        Viewer.ViewChanged += Viewer_ViewChanged;
        Viewer.View.PreviewKeyDown += View_PreviewKeyDown;
        CountFlattenable();
        Choose();
    }

    public override bool HandIn()
    {
        _editor?.Finish();
        return true;
    }

    protected override void OnDetach()
    {
        _settle.Stop();
        _unsettled.Clear();
        _editor?.Finish();
        Tab!.Changed -= Tab_Changed;
        Viewer!.ModeChanged -= Viewer_ModeChanged;
        Viewer.ViewChanged -= Viewer_ViewChanged;
        Viewer.View.PreviewKeyDown -= View_PreviewKeyDown;
        if (ReferenceEquals(Viewer.PointerTool, _active)) Viewer.PointerTool = null;
        _edit?.Clear();
        _edit = null;
        _bar?.Dispose();
        _bar = null;
    }

    private void UpdateEnabled()
    {
        MarkupGrid.IsEnabled = Palette.IsEnabled = ImportButton.IsEnabled = _allowed && !MarkWork.Running;
        ExportButton.IsEnabled = !MarkWork.Running;
    }

    private void Pick(MarkTool tool)
    {
        _tool = tool;
        _loading = true;
        _buttons[tool].IsChecked = true;
        _loading = false;
    }

    private Marker NewMarker(DocumentTab tab) => new(tab.Document, _fonts, Environment.UserName, DateTimeOffset.Now);

    private static byte Channel(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);

    private MarkStyle CurrentStyle()
    {
        double size = double.TryParse(FontSizeBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double typed) ? Math.Clamp(typed, 4, 144) : 12;
        var font = (BoldToggle.IsChecked == true ? FontStyles.Bold : FontStyles.Regular) | (ItalicToggle.IsChecked == true ? FontStyles.Italic : FontStyles.Regular);
        var line = (LineStyle)Math.Max(LineStyleBox.SelectedIndex, 0);
        return new MarkStyle(_color, WidthSlider.Value, OpacitySlider.Value / 100, FontFamilyBox.SelectedItem as string ?? Families.Value[0], size, font,
            Fills[Math.Max(FillBox.SelectedIndex, 0)].Rgb, line, Heads[Math.Max(HeadBox.SelectedIndex, 0)].Value, Icons[Math.Max(IconBox.SelectedIndex, 0)].Value);
    }

    private void ShowReadouts()
    {
        WidthReadout.Text = string.Format(CultureInfo.CurrentCulture, Loc.T("{0} pt"), WidthSlider.Value);
        OpacityReadout.Text = Loc.T("{0} %", OpacitySlider.Value);
    }

    private void Choose(bool setMode = true)
    {
        if (Viewer is not { } viewer || _edit is null) return;
        _choosing = true;
        _editor?.Finish();
        if (_tool != MarkTool.Edit) _edit.Clear();
        switch (_tool)
        {
            case MarkTool.SelectText:
                _active = null;
                if (setMode) viewer.Mode = PointerMode.Select;
                break;
            case MarkTool.Edit:
                viewer.PointerTool = _active = _edit;
                _edit.Redraw();
                break;
            default:
                viewer.PointerTool = _active = new DrawTool(viewer, _tool, CurrentStyle, Drew, p => _edit is { } e && e.Holds(p) ? e : null);
                break;
        }
        _choosing = false;
        StampRow.Visibility = _tool == MarkTool.Stamp ? Visibility.Visible : Visibility.Collapsed;
        Hint.Text = !_allowed ? Loc.T("This file does not allow comments.")
            : _tool is MarkTool.Note or MarkTool.TextBox or MarkTool.Stamp or MarkTool.Attach or MarkTool.Line or MarkTool.Arrow or MarkTool.Rectangle or MarkTool.Oval or MarkTool.Callout ? $"{Tools.First(t => t.Tool == _tool).Hint} {Loc.T("Or press Enter on the page.")}"
            : _tool is MarkTool.Polygon or MarkTool.Cloud ? $"{Tools.First(t => t.Tool == _tool).Hint} {Loc.T("With the keyboard, press Enter at each corner and Ctrl+Enter to finish.")}"
            : Tools.First(t => t.Tool == _tool).Hint;
        Hint.Visibility = Visibility.Visible;
        ShowSelected();
        _bar?.Refresh();
    }

    private void Tool_Checked(object sender, RoutedEventArgs e)
    {
        if (_loading || sender is not RadioButton { Tag: MarkTool tool }) return;
        _tool = tool;
        Choose();
    }

    // The viewer's own Hand and Select buttons take the pointer back; the mode they chose stays.
    private void Viewer_ModeChanged(object? sender, EventArgs e)
    {
        if (_choosing || _tool == MarkTool.SelectText) return;
        Pick(MarkTool.SelectText);
        Choose(setMode: false);
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e)
    {
        _edit?.Redraw();
        _bar?.Move();
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        _edit?.Refresh();
        ShowSelected();
        CountFlattenable();
    }

    private void CountFlattenable()
    {
        int count = Exchange.Flattenable(Tab!.Document);
        if ((count > 0) == (_flattenable > 0)) return;
        _flattenable = count;
        RaiseActionChanged();
    }

    private void Swatch_Checked(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _color = ((RadioButton)sender).Tag as double[];
        Look_Changed(sender, e);
    }

    private void Stamp_Changed(object sender, RoutedEventArgs e)
    {
        if (e is SelectionChangedEventArgs { AddedItems.Count: > 0 }) PictureList.SelectedIndex = -1;
        if (StampName.Text.Length == 0) StampName.SelectedIndex = 0;
    }

    // The sliders settle for a moment before they change the selected mark, so a drag is one undo step.
    private void Look_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        ShowReadouts();
        if (_edit?.Current is null) return;
        _unsettled.Add(sender is RadioButton ? "colour" : sender is Slider || sender == FillBox || sender == LineStyleBox || sender == HeadBox || sender == IconBox ? sender : "font");
        _settle.Stop();
        _settle.Start();
    }

    private void Settle_Tick(object? sender, EventArgs e)
    {
        _settle.Stop();
        var pending = _unsettled.ToList();
        _unsettled.Clear();
        if (_edit?.Current is not { } mark || Tab is null) return;
        var look = CurrentStyle();
        if (FontFamilyBox.SelectedItem is null) look = look with { Family = Marker.TextOf(mark).Family };
        Change(Loc.T("Change look"), m =>
        {
            var current = mark;
            if (pending.Contains("colour") && look.Color is { } rgb) current = m.Recolor(current, rgb);
            if (pending.Contains("font") && current.Type == AnnotationType.FreeText && Differs(Marker.TextOf(current), look)) current = m.Restyle(current, look);
            if (pending.Contains(FillBox) && Marker.TakesFill(current)) current = m.SetFill(current, look.Fill);
            if (pending.Contains(WidthSlider)) current = m.SetWidth(current, look.Width);
            if (pending.Contains(LineStyleBox) && Marker.TakesLine(current)) current = m.SetDash(current, look.Dash);
            if (pending.Contains(HeadBox) && HasHead(current)) current = m.SetEnding(current, look.Head);
            if (pending.Contains(IconBox) && current.Type == AnnotationType.Text) current = m.SetIcon(current, look.Icon);
            if (pending.Contains(OpacitySlider)) m.SetOpacity(current, look.Opacity);
        });
    }

    // A head chosen on the start of a line is another app's; only the end is offered.
    private static bool HasHead(PdfAnnotation a) => a.Type == AnnotationType.Line && a.StartEnding == LineEnding.None;

    private static bool Differs(FreeTextStyle text, MarkStyle look) => text.Family != look.Family || text.Size != look.Size || text.Font != look.Font;
}
