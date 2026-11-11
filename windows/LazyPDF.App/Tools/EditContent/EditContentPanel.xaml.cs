using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using TextBlock = System.Windows.Controls.TextBlock;

namespace LazyPDF.App.Tools.EditContent;

/// <summary>
/// Changes what is on the pages: click a line of text and type over it, restyle or reflow a paragraph, move, resize,
/// turn, delete and reorder pictures and shapes, add text boxes, pictures and links, and replace words in the whole
/// file. The pointer work is in <see cref="EditSurface"/>, the typing in <see cref="InPlaceEditor"/>, the calls to
/// Core in <see cref="PageEdits"/>; this panel joins them to the controls.
/// </summary>
public sealed partial class EditContentPanel : ToolPanel
{
    private PageEdits? _edits;
    private EditSurface? _surface;
    private InPlaceEditor? _editor;
    private DocumentTab? _tab;

    // Set while this panel changes the document, so that the change is not mistaken for someone else's (an undo).
    private bool _editing;
    private bool _loading;

    // The person said to go on with a signed file; asked once for as long as the panel is attached.
    private bool _signedOk;

    public EditContentPanel()
    {
        InitializeComponent();
        Swatches(TextColors, color => Restyle(new TextStyleChange(Color: color), Loc.T("Colour changed.")));
        Swatches(FillColors, color => ShapeStyle(fill: color, stroke: null, width: null));
        Swatches(LineColors, color => ShapeStyle(fill: null, stroke: color, width: null));
        FontBox.ItemsSource = Fonts.SystemFontFamilies.Select(f => f.Source).Order().ToList();
        _opacityTimer.Tick += OpacityTimer_Tick;
        RefreshPanel();
    }

    public override ToolAction? Action => _pending switch
    {
        Pending.Line or Pending.Paragraph or Pending.NewBox => new ToolAction(Loc.T("Apply text"), "", () => _editor?.IsOpen == true, ApplyTextAsync),
        _ when _surface?.Mode == EditMode.Link && _linkArea is not null =>
            new ToolAction(_linkOld is null ? Loc.T("Add link") : Loc.T("Save link"), "", () => LinkTarget() is not null, ApplyLinkAsync),
        _ => null,
    };

    protected override void OnAttach()
    {
        _tab = Tab!;
        _signedOk = false;
        _edits = new PageEdits(_tab, new SystemFontSource(), new WicImageCodec());
        _surface = new EditSurface(Viewer!, _edits);
        _editor = new InPlaceEditor(Viewer!);
        _surface.Pressing += Surface_Pressing;
        _surface.SelectionChanged += Surface_SelectionChanged;
        _surface.TextClicked += Surface_TextClicked;
        _surface.AreaDrawn += Surface_AreaDrawn;
        _surface.LinkPicked += Surface_LinkPicked;
        _surface.MoveRequested += Surface_MoveRequested;
        _surface.ResizeRequested += Surface_ResizeRequested;
        _editor.Committed += Editor_Committed;
        _editor.Cancelled += Editor_Cancelled;
        _tab.Changed += Tab_Changed;
        Viewer!.View.PreviewKeyDown += View_PreviewKeyDown;
        Viewer.ModeChanged += Viewer_ModeChanged;
        Viewer.ViewChanged += Viewer_ViewChanged;
        _surface.Attach();
        ModeSelect.IsChecked = true;
        HideMessage();
        RefreshPanel();
    }

    public override bool HandIn()
    {
        FlushOpacity();
        if (_pending != Pending.None && !CommitEditor() && MessageRow.Visibility == Visibility.Visible)
        {
            Host!.ShowProblem(new Problem(Loc.T("Typed text was not kept"), MessageText.Text));
        }
        return true;
    }

    protected override void OnDetach()
    {
        HandIn();
        _editor!.Close();
        _pending = Pending.None;
        _linkArea = null;
        _linkOld = null;
        _surface!.Detach();
        _tab!.Changed -= Tab_Changed;
        Viewer!.View.PreviewKeyDown -= View_PreviewKeyDown;
        Viewer.ModeChanged -= Viewer_ModeChanged;
        Viewer.ViewChanged -= Viewer_ViewChanged;
        _edits = null;
        _surface = null;
        _editor = null;
        _tab = null;
    }

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (_surface is null) return;
        HideMessage();
        FinishPending();
        _surface.Clear();
        _surface.Mode = ModeText.IsChecked == true ? EditMode.TextBox : ModeLink.IsChecked == true ? EditMode.Link : EditMode.Select;
        _linkArea = null;
        _linkOld = null;
        _surface.ActiveLink = null;
        RefreshPanel();
    }

    // The Hand or Select button of the viewer took the pointer; it comes back when a mode here is picked.
    private void Viewer_ViewChanged(object? sender, EventArgs e) => _editor?.Upright();

    private void Viewer_ModeChanged(object? sender, EventArgs e)
    {
        if (_surface is not { IsActive: false }) return;
        FinishPending();
        _surface.Detach();
        RefreshPanel();
    }

    private void Mode_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is { IsActive: false } surface) surface.Attach();
        RefreshPanel();
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        if (_editing || _surface is null) return;
        if (HasTyped()) Host?.ShowProblem(new Problem(Loc.T("Typed text was not kept"), Loc.T("The file changed while you typed. Type it again.")));
        _editor!.Close();
        _pending = Pending.None;
        _surface.Clear();
        _surface.Refresh();
        RefreshPanel();
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_surface is null || Keyboard.FocusedElement is TextBox) return;
        if (e.Key == Key.Delete && _surface.Selected.Count > 0 && _surface.Mode == EditMode.Select)
        {
            e.Handled = true;
            Delete_Click(this, e);
        }
        else if (e.Key == Key.Escape && (_surface.Selected.Count > 0 || _surface.Mode != EditMode.Select))
        {
            e.Handled = true;
            if (_surface.Mode == EditMode.Crop) _surface.Mode = EditMode.Select;
            else if (_surface.Selected.Count > 0) _surface.Clear();
            else ModeSelect.IsChecked = true;
            RefreshPanel();
        }
    }

    private void Surface_Pressing(object? sender, EventArgs e) => FinishPending();

    // Clearing the selection keeps what is shown: a click on the page often ends an edit, and its note or reason is for that.
    private void Surface_SelectionChanged(object? sender, EventArgs e)
    {
        FlushOpacity();
        if (_surface!.Selected.Count > 0) HideMessage();
        RefreshPanel();
    }

    private void Surface_MoveRequested(int page, IReadOnlyList<int> ids, double dx, double dy) =>
        Apply(() => _edits!.Move(page, ids, dx, dy), Loc.T("Moved."));

    private void Surface_ResizeRequested(int page, IReadOnlyList<int> ids, PdfRect bounds) =>
        Apply(() => _edits!.Resize(page, ids, bounds), Loc.T("Resized."));

    // ----- Edits

    /// <summary>Runs one edit of the document, shows what came of it and draws the selection again.</summary>
    private bool Apply(Func<EditOutcome> change, string status)
    {
        if (_edits is null || !Allowed(() => Apply(change, status))) return false;
        var shape = Shape();
        EditOutcome outcome;
        _editing = true;
        try
        {
            outcome = change();
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or PdfReadException)
        {
            outcome = new EditOutcome(false, Loc.T("The page changed. Select the object again."));
            System.Diagnostics.Trace.TraceError(e.ToString());
        }
        finally
        {
            _editing = false;
        }
        if (outcome.Done)
        {
            Host?.SetStatus(status);

            // Object numbers are places in a list that is read again; if its shape changed they may name other objects.
            if (shape is null || Shape()!.SequenceEqual(shape)) _surface!.Refresh();
            else _surface!.Clear();
        }
        ShowOutcome(outcome);
        RefreshPanel();
        return outcome.Done;
    }

    private List<PageObjectKind>? Shape() =>
        _surface is { Page: >= 0 } surface ? [.. _edits!.Editor(surface.Page).Objects.Select(o => o.Kind)] : null;

    // False when the edit has to wait: the file forbids it, or the info bar asks first and goes on with it on a yes.
    private bool Allowed(Action go)
    {
        var document = _tab!.Document;
        if (Clearance.Refusal(document) is { } problem)
        {
            Host?.ShowProblem(problem);
            return false;
        }
        if (!document.IsSigned || _signedOk) return true;
        Host?.ShowNotice(Loc.T("Check before going on"), Loc.T("This file is signed, so changing it breaks the signatures."), new NoticeAction(Loc.T("Go on anyway"), () =>
        {
            _signedOk = true;
            go();
        }));
        return false;
    }

    private void ShowOutcome(EditOutcome outcome)
    {
        if (outcome.Problem is { } problem) ShowMessage("", problem, caution: true);
        else if (outcome.Note is { } note) ShowMessage("", note, caution: false);
        else HideMessage();
    }

    private void ShowMessage(string glyph, string text, bool caution)
    {
        MessageGlyph.Text = glyph;
        if (caution) MessageGlyph.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        else MessageGlyph.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        MessageText.Text = text;
        MessageRow.Visibility = Visibility.Visible;
    }

    private void HideMessage() => MessageRow.Visibility = Visibility.Collapsed;

    // ----- What the panel shows

    private IReadOnlyList<PageObject> SelectedObjects() =>
        _surface is { Page: >= 0 } surface ? _edits!.Objects(surface.Page, surface.Selected) : [];

    private TextObject? SelectedText() => SelectedObjects() is [TextObject text] ? text : null;

    private void RefreshPanel()
    {
        if (_surface is null) return;
        var objects = SelectedObjects();
        var mode = _surface.Mode;
        var text = objects is [TextObject t] ? t : null;
        var image = objects is [ImageObject i] ? i : null;
        bool shapes = objects.Count > 0 && objects.All(o => o is PathObject);
        bool inSelect = mode == EditMode.Select;
        _loading = true;
        try
        {
            Hint.Text = !_surface.IsActive ? Loc.T("Pick a mode above to edit the page again.") : mode switch
            {
                EditMode.TextBox => Loc.T("Drag a box on the page, then type."),
                EditMode.Link => Loc.T("Drag an area to make a link, or click a link to change it."),
                EditMode.Crop => Loc.T("Drag the part of the picture to keep."),
                _ when objects.Count == 0 => Loc.T("Click text or a picture to change it. Drag to select several."),
                _ => Loc.T("Drag to move. Drag a handle to resize."),
            };
            AddPicture.Visibility = inSelect ? Visibility.Visible : Visibility.Collapsed;
            TextSection.Visibility = text is not null || mode == EditMode.TextBox ? Visibility.Visible : Visibility.Collapsed;
            ImageSection.Visibility = image is not null && inSelect ? Visibility.Visible : Visibility.Collapsed;
            ShapeSection.Visibility = shapes && inSelect ? Visibility.Visible : Visibility.Collapsed;
            OpacitySection.Visibility = objects.Count > 0 && inSelect && objects.All(o => o is not TextObject) ? Visibility.Visible : Visibility.Collapsed;
            ArrangeSection.Visibility = objects.Count > 0 && inSelect ? Visibility.Visible : Visibility.Collapsed;
            OrderGrid.Visibility = objects is [ImageObject or PathObject] ? Visibility.Visible : Visibility.Collapsed;
            LinkSection.Visibility = mode == EditMode.Link && _linkArea is not null ? Visibility.Visible : Visibility.Collapsed;
            RemoveLink.Visibility = _linkOld is null ? Visibility.Collapsed : Visibility.Visible;
            if (TextSection.Visibility == Visibility.Visible) FillText(text);
            if (image is not null) OpacitySlider.Value = Math.Round(image.Opacity * 100);
            else if (objects is [PathObject p]) OpacitySlider.Value = Math.Round(p.Opacity * 100);
            if (objects is [PathObject one]) WidthBox.Text = Number(one.LineWidth);
            OpacityReadout.Text = Loc.T("{0}%", (int)OpacitySlider.Value);
        }
        finally
        {
            _loading = false;
        }
        RaiseActionChanged();
    }

    private static string Number(double value) => Math.Round(value, 1).ToString("0.#");

    private void Swatches(WrapPanel host, Action<RgbColor> picked)
    {
        foreach (var (name, color) in Palette.Colors)
        {
            var chip = new Button { Style = (Style)FindResource("SwatchStyle"), Background = new SolidColorBrush(Palette.Brush(color)), ToolTip = name };
            System.Windows.Automation.AutomationProperties.SetName(chip, name);
            chip.Click += (_, _) => picked(color);
            host.Children.Add(chip);
        }
    }
}
