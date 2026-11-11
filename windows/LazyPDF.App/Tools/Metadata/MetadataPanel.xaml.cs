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

    private const int MaxCustom = 100;

    private sealed class CustomRow
    {
        public string Name { get; set; } = "";
        public string Value { get; set; } = "";
    }

    private readonly ToolAction _action;
    private readonly System.Collections.ObjectModel.ObservableCollection<CustomRow> _custom = [];
    private string? _customProblem;
    private DocumentMetadata _metadata = null!;
    private ViewerSettings _view = null!;
    private bool _loading = true;
    private bool _changed;
    private Guid _editing;
    private Guid _dropped;

    public MetadataPanel()
    {
        InitializeComponent();
        _action = new ToolAction(Loc.T("Save properties"), "", () => _customProblem is null && (_changed || _dropped == Tab?.Id), Save);
        CustomList.ItemsSource = _custom;
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

    // Typed properties go into the file on Save, on leaving the panel and on close, as one undo step each time.
    // A signed file asks first, so there the caller is told to wait and leaving the panel does not ask again.
    public override bool HandIn()
    {
        if (Tab is null || !_changed || _customProblem is null) return Store(true);
        Host!.ShowNotice(Loc.T("Properties not saved"), _customProblem);
        return false;
    }

    private bool Store(bool notify)
    {
        if (Tab is null) return true;
        if (!_changed || _customProblem is not null)
        {
            if (MetadataEdit.ShowDropNotice(notify, _dropped == Tab.Id)) ShowDropNotice();
            return true;
        }
        bool asks = AsksFirst;
        _ = RunAsync(notify);
        return !asks;
    }

    private bool AsksFirst => Tab is { } tab && tab.Document.IsSigned && ChangeGate.Refusal(tab.Document) is null;

    private void Fields_FocusWithinChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.NewValue is false && !AsksFirst) Store(false);
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
        _custom.Clear();
        foreach (var (name, value) in _metadata.Custom) _custom.Add(new CustomRow { Name = name, Value = value });
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
            Custom = MetadataEdit.Custom(CustomPairs()),
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
        // The form drops empty values, so the file's own are left out of the comparison.
        var kept = _metadata with { Custom = MetadataEdit.Custom(_metadata.Custom.Select(pair => (pair.Key, pair.Value))) };
        _changed = !MetadataEdit.Same(metadata, kept) || view != _view;
        _customProblem = MetadataEdit.CustomProblem(CustomPairs(), _metadata.Custom);
        CustomNote.Text = MetadataEdit.CustomNote(CustomPairs(), _metadata.Custom) ?? "";
        AddCustomButton.IsEnabled = _custom.Count < MaxCustom;
        if (_changed) _editing = Tab.Id;
        RaiseActionChanged();
    }

    private List<(string Name, string Value)> CustomPairs() => _custom.Select(row => (row.Name, row.Value)).ToList();

    // A new row sets its text once, which is no edit; reading the form for each of thousands of rows would take minutes.
    private void CustomName_Changed(object sender, TextChangedEventArgs e)
    {
        var box = (TextBox)sender;
        var row = (CustomRow)box.DataContext;
        if (row.Name == box.Text) return;
        row.Name = box.Text;
        Field_Changed(sender, e);
    }

    private void CustomValue_Changed(object sender, TextChangedEventArgs e)
    {
        var box = (TextBox)sender;
        var row = (CustomRow)box.DataContext;
        if (row.Value == box.Text) return;
        row.Value = box.Text;
        Field_Changed(sender, e);
    }

    private void AddCustom_Click(object sender, RoutedEventArgs e)
    {
        _custom.Add(new CustomRow());
        Field_Changed(sender, e);
    }

    private void RemoveCustom_Click(object sender, RoutedEventArgs e)
    {
        _custom.Remove((CustomRow)((Button)sender).DataContext);
        Field_Changed(sender, e);
    }

    // Leaving the panel may have saved the typed text already; the button then only shows the notice.
    private Task Save()
    {
        if (_changed) return RunAsync(true);
        ShowDropNotice();
        return Task.CompletedTask;
    }

    private Task RunAsync(bool notify)
    {
        var tab = Tab!;
        var host = Host!;
        var (metadata, view) = ReadForm();
        bool touch = TouchModifiedBox.IsChecked == true;
        bool drops = MetadataEdit.DropsText(_metadata, metadata);
        return ChangeGate.RunAsync(tab, host, _action.Text, () =>
        {
            MetadataEdit.Write(tab.Document, metadata, view, touch, DateTimeOffset.Now);
            if (tab.Commit(Loc.T("Properties")))
            {
                host.SetStatus(Loc.T("Properties changed."));
                // Leaving the panel commits it, so a drop is remembered until the properties are saved.
                if (drops)
                {
                    _dropped = tab.Id;
                    RaiseActionChanged();
                }
                if (MetadataEdit.ShowDropNotice(notify, _dropped == tab.Id)) ShowDropNotice();
            }
            return Task.CompletedTask;
        });
    }

    private void ShowDropNotice()
    {
        _dropped = Guid.Empty;
        RaiseActionChanged();
        Host?.ShowNotice(Loc.T("Old values are still in the file"), Loc.T("The earlier title, author, subject, keywords or custom values can still be found in the file's history. Clean for sharing removes them."));
    }
}
