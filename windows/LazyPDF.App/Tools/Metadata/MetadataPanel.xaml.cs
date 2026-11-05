using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Metadata;

/// <summary>The properties stored in the file, and how it opens and prints in other viewers.</summary>
public sealed partial class MetadataPanel : ToolPanel
{
    // A date outside this range may not fit the local offset. The picker lets a typed one through, so ReadForm checks it too.
    private static readonly DateTime FirstDay = new(1900, 1, 1);
    private static readonly DateTime LastDay = new(2100, 1, 1);

    private readonly ToolAction _action;
    private DocumentMetadata _metadata = null!;
    private ViewerSettings _view = null!;
    private bool _loading = true;
    private bool _changed;
    private Guid _editing;

    public MetadataPanel()
    {
        InitializeComponent();
        _action = new ToolAction(Loc.T("Save properties"), "", () => _changed, RunAsync);
        ModeBox.ItemsSource = MetadataEdit.Modes.Select(MetadataEdit.ModeName).ToList();
        LayoutBox.ItemsSource = MetadataEdit.Layouts.Select(MetadataEdit.LayoutName).ToList();
        SidesBox.ItemsSource = MetadataEdit.Sides.Select(MetadataEdit.SidesName).ToList();
        CopiesBox.ItemsSource = new[] { Loc.T("Printer default"), "2", "3", "4", "5" };
        CreatedPicker.DisplayDateStart = FirstDay;
        CreatedPicker.DisplayDateEnd = LastDay;
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Load(_changed && _editing == Tab.Id);
    }

    protected override void OnDetach() => Tab!.Changed -= Tab_Changed;

    // Typed properties go into the file on Save, on leaving a field and on close, as one undo step each time.
    // A signed file asks first, so there the caller is told to wait and leaving a field does not ask again.
    public override bool HandIn()
    {
        if (!_changed || Tab is null) return true;
        bool asks = AsksFirst;
        _ = RunAsync();
        return !asks;
    }

    private bool AsksFirst => Tab is { } tab && tab.Document.IsSigned && ChangeGate.Refusal(tab.Document) is null;

    private void Fields_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (e.OriginalSource is TextBox && !AsksFirst) HandIn();
    }

    private void Tab_Changed(object? sender, EventArgs e) => Load(_changed);

    // Typed properties are not in the file yet, so a change made elsewhere reads the file again but keeps them.
    private void Load(bool keepEdits)
    {
        var document = Tab!.Document;
        _metadata = DocumentMetadata.Read(document);
        _view = ViewerSettings.Read(document);
        _loading = true;
        ShowFacts();
        if (!keepEdits) ShowForm();
        _loading = false;
        Field_Changed(this, new RoutedEventArgs());
    }

    private void ShowFacts()
    {
        ModifiedText.Text = _metadata.Modified is { } modified ? Loc.T("Changed {0}", modified.LocalDateTime.ToString("g")) : Loc.T("No changed date.");
        string maker = string.Join(" · ", new[] { _metadata.Creator, _metadata.Producer }.Where(s => !string.IsNullOrEmpty(s)));
        MakerText.Text = maker;
        MakerText.Visibility = maker.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowForm()
    {
        TitleBox.Text = _metadata.Title ?? "";
        AuthorBox.Text = _metadata.Author ?? "";
        SubjectBox.Text = _metadata.Subject ?? "";
        KeywordsBox.Text = _metadata.Keywords ?? "";
        CreatedPicker.SelectedDate = _metadata.Created?.LocalDateTime.Date;
        ModeBox.SelectedIndex = Array.IndexOf(MetadataEdit.Modes, _view.PageMode);
        LayoutBox.SelectedIndex = Array.IndexOf(MetadataEdit.Layouts, _view.PageLayout);
        LanguageBox.Text = _view.Language ?? "";
        TitleBarBox.IsChecked = _view.DisplayDocTitle;
        ToolbarBox.IsChecked = _view.HideToolbar;
        MenuBox.IsChecked = _view.HideMenubar;
        ControlsBox.IsChecked = _view.HideWindowUI;
        FitBox.IsChecked = _view.FitWindow;
        CentreBox.IsChecked = _view.CenterWindow;
        RightToLeftBox.IsChecked = _view.RightToLeft;
        ActualSizeBox.IsChecked = _view.PrintScalingNone;
        SidesBox.SelectedIndex = Math.Max(0, Array.IndexOf(MetadataEdit.Sides, _view.Duplex));
        CopiesBox.SelectedIndex = _view.NumCopies is { } copies ? copies - 1 : 0;
    }

    private (DocumentMetadata Metadata, ViewerSettings View) ReadForm()
    {
        static string? Text(string value) => value.Length == 0 ? null : value;
        var picked = CreatedPicker.SelectedDate;
        var created = picked is null ? null
            : picked.Value.Date == _metadata.Created?.LocalDateTime.Date || picked.Value.Date < FirstDay || picked.Value.Date > LastDay ? _metadata.Created
            : new DateTimeOffset(picked.Value.Date);
        var metadata = _metadata with
        {
            Title = Text(TitleBox.Text),
            Author = Text(AuthorBox.Text),
            Subject = Text(SubjectBox.Text),
            Keywords = Text(KeywordsBox.Text),
            Created = created,
        };
        var view = _view with
        {
            PageMode = MetadataEdit.Modes[Math.Max(0, ModeBox.SelectedIndex)],
            PageLayout = MetadataEdit.Layouts[Math.Max(0, LayoutBox.SelectedIndex)],
            Language = Text(LanguageBox.Text),
            DisplayDocTitle = TitleBarBox.IsChecked == true,
            HideToolbar = ToolbarBox.IsChecked == true,
            HideMenubar = MenuBox.IsChecked == true,
            HideWindowUI = ControlsBox.IsChecked == true,
            FitWindow = FitBox.IsChecked == true,
            CenterWindow = CentreBox.IsChecked == true,
            RightToLeft = RightToLeftBox.IsChecked == true,
            PrintScalingNone = ActualSizeBox.IsChecked == true,
            Duplex = MetadataEdit.Sides[Math.Max(0, SidesBox.SelectedIndex)],
            NumCopies = CopiesBox.SelectedIndex > 0 ? CopiesBox.SelectedIndex + 1 : null,
        };
        return (metadata, view);
    }

    private void Field_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading || Tab is null) return;
        var (metadata, view) = ReadForm();
        _changed = metadata != _metadata || view != _view;
        if (_changed) _editing = Tab.Id;
        RaiseActionChanged();
    }

    private Task RunAsync()
    {
        var tab = Tab!;
        var host = Host!;
        var (metadata, view) = ReadForm();
        bool touch = TouchModifiedBox.IsChecked == true;
        return ChangeGate.RunAsync(tab, host, _action.Text, () =>
        {
            MetadataEdit.Write(tab.Document, metadata, view, touch, DateTimeOffset.Now);
            if (tab.Commit(Loc.T("Properties"))) host.SetStatus(Loc.T("Properties changed."));
            return Task.CompletedTask;
        });
    }
}
