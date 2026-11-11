using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

/// <summary>
/// Filling a form on the page and editing its fields. Filling puts real controls over the fields; editing draws,
/// moves, resizes and sets up the fields themselves. Every change goes through the tab as one undoable step.
/// </summary>
public sealed partial class FormsPanel : ToolPanel
{
    private readonly SystemFontSource _fonts = new();
    private readonly ToolAction _flatten;
    private PdfForm? _form;
    private FillLayer? _fill;
    private FieldFrames? _frames;
    private FieldTool? _tool;
    private List<FieldRow> _rows = [];
    private bool _loading;
    private bool _canEdit;
    private bool _working;
    private bool _signedOk;
    private int _revision;

    public FormsPanel()
    {
        InitializeComponent();
        _flatten = new ToolAction(Loc.T("Flatten form"), "", CanFlatten, FlattenAsync, Loc.T("Makes the fields part of the page. They can no longer be filled in or changed."));
        KindBox.DisplayMemberPath = nameof(KindChoice.Text);
        KindBox.ItemsSource = new[] { new KindChoice(Loc.T("None"), null) }.Concat(
            Enum.GetValues<FieldKind>().Select(kind => new KindChoice(FormText.KindName(kind), kind))).ToList();
        KindBox.SelectedIndex = 0;
        FillStyleChoices();
        TabBox.DisplayMemberPath = nameof(TabChoice.Text);
        TabBox.ItemsSource = new TabChoice[]
        {
            new(Loc.T("Order in the file"), TabOrder.Annotations),
            new(Loc.T("By row"), TabOrder.Row),
            new(Loc.T("By column"), TabOrder.Column),
        };
        FillMode.IsChecked = true;
    }

    public override ToolAction? Action => _flatten;

    internal IDocumentViewer View => Viewer!;

    private bool Designing => DesignMode.IsChecked == true;

    private PdfForm Form => _form ??= FormEdits.Read(Tab!, _fonts);

    protected override void OnAttach()
    {
        _fill = new FillLayer(Viewer!, Enter, Choose, ResetFields, name => Host!.OpenSigning(name), text => Host!.ShowNotice(Loc.T("This button does nothing here"), text)) { Highlight = HighlightToggle.IsChecked == true };
        _frames = new FieldFrames(Viewer!);
        _tool = new FieldTool(this);
        Tab!.Changed += Tab_Changed;
        Viewer!.ViewChanged += Viewer_ViewChanged;
        Viewer.PageChanged += Viewer_PageChanged;
        Viewer.ModeChanged += Viewer_ModeChanged;
        InputManager.Current.PreProcessInput += Input_PreProcess;
        Viewer.View.PreviewKeyDown += View_PreviewKeyDown;
        _selected = null;
        _picked = [];
        _found = [];
        _signedOk = false;
        _working = false;
        FoundPane.Visibility = Visibility.Collapsed;
        Reload();
    }

    public override bool HandIn()
    {
        _fill?.Flush();
        return true;
    }

    protected override void OnDetach()
    {
        InputManager.Current.PreProcessInput -= Input_PreProcess;
        Viewer!.View.PreviewKeyDown -= View_PreviewKeyDown;
        _fill!.Flush();
        Tab!.Changed -= Tab_Changed;
        Viewer!.ViewChanged -= Viewer_ViewChanged;
        Viewer.PageChanged -= Viewer_PageChanged;
        Viewer.ModeChanged -= Viewer_ModeChanged;
        _fill.Clear();
        _frames!.Clear();
        if (ReferenceEquals(Viewer.PointerTool, _tool)) Viewer.PointerTool = null;
        FieldList.ItemsSource = null;
        FoundList.ItemsSource = null;
        _rows = [];
        _fill = null;
        _frames = null;
        _tool = null;
        _form = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => Reload();

    // The viewer hears of a changed file before the panel does; until the panel has read it again its form is the old one.
    private void Viewer_ViewChanged(object? sender, EventArgs e)
    {
        if (Tab!.Revision != _revision) return;
        if (!Designing) _fill?.Follow();
        _frames?.Follow();
    }

    private void Viewer_PageChanged(object? sender, EventArgs e)
    {
        if (Designing) ShowTabOrder();
    }

    private void Viewer_ModeChanged(object? sender, EventArgs e)
    {
        if (Designing) FillMode.IsChecked = true;
    }

    // Commands that read the file do not move the keyboard first, so what is typed is handed in before they run.
    private void Input_PreProcess(object sender, PreProcessInputEventArgs e)
    {
        if (e.StagingItem.Input is not KeyEventArgs key || key.RoutedEvent != Keyboard.PreviewKeyDownEvent) return;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && key.Key is Key.S or Key.W or Key.Tab or Key.P) _fill?.Flush();
    }

    private void Reload()
    {
        _form = null;
        _revision = Tab!.Revision;
        var form = Form;
        bool open = form.Xfa != XfaKind.Dynamic && form.CanFill;
        _canEdit = open && FormEdits.CanModify(form.Document);
        var rows = Rows(form);
        if (!rows.SequenceEqual(_rows))
        {
            _rows = rows;
            _loading = true;
            FieldList.ItemsSource = rows;
            _loading = false;
        }
        ShowSummary(form);
        FillPane.Visibility = Designing ? Visibility.Collapsed : Visibility.Visible;
        DesignPane.Visibility = Designing ? Visibility.Visible : Visibility.Collapsed;
        FillPane.IsEnabled = DataPane.IsEnabled = open;
        DesignPane.IsEnabled = _canEdit;
        SyncTool();
        if (Designing)
        {
            _fill!.Clear();
            ShowDesign(form);
        }
        else
        {
            _frames!.Clear();
            _fill!.Show(form, open);
        }
        RaiseActionChanged();
    }

    private void SyncTool()
    {
        if (Designing && _canEdit) Viewer!.PointerTool = _tool;
        else if (ReferenceEquals(Viewer!.PointerTool, _tool)) Viewer.PointerTool = null;
    }

    private static List<FieldRow> Rows(PdfForm form)
    {
        var seen = new Dictionary<string, int>();
        return [.. form.Fields.Select(field =>
        {
            int ordinal = seen.GetValueOrDefault(field.Name);
            seen[field.Name] = ordinal + 1;
            return Row(field, ordinal);
        })];
    }

    private static FieldRow Row(FormField field, int ordinal)
    {
        int page = field.Widgets.Count > 0 ? field.Widgets[0].PageIndex : -1;
        string kind = FormText.KindName(field.Kind);
        return new FieldRow(field.Name, page < 0 ? kind : Loc.T("{0}, page {1}", kind, page + 1), page, 0, ordinal);
    }

    private void ShowSummary(PdfForm form)
    {
        int required = form.Fields.Count(f => f.Has(FieldFlags.Required));
        Summary.Text = form.Fields.Count == 0 ? Loc.T("This file has no form fields.")
            : required == 0 ? Loc.Plural(form.Fields.Count, "{0} field", "{0} fields")
            : Loc.Plural(form.Fields.Count, "{0} field, {1} required", "{0} fields, {1} required", required);
        string? note = form.Xfa == XfaKind.Dynamic ? FormText.DynamicXfa
            : !form.CanFill ? Loc.T("The permissions of this file do not allow filling in forms.")
            : Designing && !_canEdit ? Loc.T("The permissions of this file do not allow changing its fields.")
            : form.Xfa == XfaKind.Static ? Loc.T("This form also has XFA data. Changing a field removes it.")
            : form.Fields.Count == 0 ? Loc.T("Choose Edit fields to add some, or to find the blanks of a form.")
            : null;
        Note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        NoteText.Text = note;
    }

    private bool CanFlatten() =>
        Tab is not null && !_working && Form is { Fields.Count: > 0, CanFill: true } form && form.Xfa != XfaKind.Dynamic && FormEdits.CanModify(form.Document);

    private async Task FlattenAsync()
    {
        if (Signed(async () => await FlattenAsync())) return;
        var host = Host!;
        int burned = await RunEditAsync(Loc.T("Flattening the form"), Loc.T("Flatten form"), form => form.Flatten());
        if (burned > 0) host.SetStatus(Loc.Plural(burned, "{0} field flattened.", "{0} fields flattened."));
    }

    private async void Reset_Click(object sender, RoutedEventArgs e)
    {
        if (Signed(() => Reset_Click(sender, e))) return;
        var host = Host!;
        int reset = await RunEditAsync(Loc.T("Resetting the form"), Loc.T("Reset form"), form => form.Reset());
        if (reset > 0) host.SetStatus(Loc.Plural(reset, "{0} field reset.", "{0} fields reset."));
    }

    // The edit runs off the UI thread on the open document, so the panel and the controls over the page keep still meanwhile.
    private async Task<int> RunEditAsync(string busy, string label, Func<PdfForm, int> edit)
    {
        var tab = Tab!;
        int done = 0;
        _working = true;
        IsEnabled = false;
        RaiseActionChanged();
        try
        {
            await Host!.RunBusyAsync(busy, async token => done = await GuardAsync(() => FormEdits.ApplyAsync(tab, _fonts, label, edit, token)));
        }
        finally
        {
            _working = false;
            IsEnabled = true;
            RaiseActionChanged();
        }
        return done;
    }

    private void Highlight_Click(object sender, RoutedEventArgs e)
    {
        if (_fill is not null) _fill.Highlight = HighlightToggle.IsChecked == true;
    }

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (Tab is null) return;
        _selected = null;
        _picked = [];
        Reload();
    }

    private void FieldList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (Designing && FieldList.SelectedItems.Count == 0)
        {
            Select(null, 0);
            return;
        }
        if ((e.AddedItems.OfType<FieldRow>().LastOrDefault() ?? FieldList.SelectedItem as FieldRow) is not { } row
            || Form.FindAll(row.Name).ElementAtOrDefault(row.Ordinal)?.Widgets.ElementAtOrDefault(row.Index) is not { PageIndex: >= 0 } widget) return;
        var d = Viewer!.Geometry(widget.PageIndex).ToDisplay(widget.Rect);
        Viewer.GoToPage(widget.PageIndex);
        Viewer.Reveal(widget.PageIndex, new Rect(d.X, d.Y, d.Width, d.Height));
        if (Designing)
        {
            var others = FieldList.SelectedItems.OfType<FieldRow>().Where(r => r != row && r.Page == row.Page).Select(r => (r.Name, r.Index, r.Ordinal));
            Pick([.. others, (row.Name, row.Index, row.Ordinal)]);
        }
        else Dispatcher.InvokeAsync(() => _fill?.Focus(row.Name, row.Index), DispatcherPriority.Loaded);
    }

    // What the person did in a control over a page. The answer is whether the field kept it.
    private bool Enter(string name, string? text)
    {
        if (Tab is null) return false;
        var form = Form;
        if (text is not null && form.Find(name) is { Kind: FieldKind.Text or FieldKind.ComboBox } field && form.Validate(field, text) is { } message)
        {
            Host!.ShowProblem(new Problem(Loc.T("Value not accepted"), message));
            return false;
        }
        return Fill(f => f.SetValue(name, text));
    }

    private bool Choose(string name, IReadOnlyList<string> picked) => Tab is not null && Fill(f => f.SetChoices(name, picked));

    private void ResetFields(IReadOnlyList<string>? names) =>
        Edit(Loc.T("Reset form"), form => names is null ? form.Reset() : names.Sum(name => form.Reset(name)), () => ResetFields(names));

    private bool Fill(Func<PdfForm, FormFillResult> fill)
    {
        bool xfa = Form.Xfa == XfaKind.Static;
        if (Edit(Loc.T("Fill form field"), fill, () => Fill(fill)) is not { } result) return false;
        if (result.Rejected.Count > 0)
        {
            Host!.ShowProblem(new Problem(Loc.T("Value not accepted"), Loc.T("This field does not take that value. Check it and try again.")));
            return false;
        }
        if (result.NotRun.Count > 0) Host!.ShowNotice(Loc.T("Script not run"), FormText.ScriptNotRun);
        else if (xfa) Host!.ShowNotice(Loc.T("XFA data removed"), FormText.XfaRemoved);
        return true;
    }

    // One undoable step. Nothing happens while an edit runs, or before the person has agreed to change a signed file.
    private T? Edit<T>(string label, Func<PdfForm, T> edit, Action? again = null)
    {
        if (_working || Signed(again)) return default;
        return Guard(() => FormEdits.Apply(Tab!, _fonts, label, edit));
    }

    // A change to a signed file leaves the signatures not covering what is now in it, and a certified file may forbid the change.
    private bool Signed(Action? again = null)
    {
        if (_signedOk || !Tab!.Document.IsSigned) return false;
        var host = Host!;
        host.ShowNotice(Loc.T("File is signed"), Loc.T("A change breaks its signatures or its certification. Change it only if that is fine."),
            new NoticeAction(Loc.T("Change anyway"), () =>
            {
                _signedOk = true;
                if (again is not null) again();
                else host.SetStatus(Loc.T("Now make the change again."));
            }));
        return true;
    }

    // Core refuses what it cannot do with an exception whose text says what to change.
    private T? Guard<T>(Func<T> run)
    {
        try
        {
            return run();
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or PdfReadException)
        {
            _form = null;
            Host?.ShowProblem(FormEdits.ProblemOf(error));
            return default;
        }
    }

    private async Task<int> GuardAsync(Func<Task<int>> run)
    {
        try
        {
            return await run();
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or PdfReadException)
        {
            _form = null;
            Host?.ShowProblem(FormEdits.ProblemOf(error));
            return 0;
        }
    }
}
