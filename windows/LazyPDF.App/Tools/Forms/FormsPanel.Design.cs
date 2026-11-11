// Editing the fields: the field the pointer tool selected, its properties in the card, drawing, moving and
// resizing, the tab order of the page and the fields the detector finds.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

public sealed partial class FormsPanel
{
    private string? _selected;
    private int _selectedIndex;
    private int _selectedOrdinal;
    private HashSet<(string Name, int Index, int Ordinal)> _picked = [];
    private List<FoundRow> _found = [];

    internal FieldKind? NewKind => (KindBox.SelectedItem as KindChoice)?.Kind;

    /// <param name="ordinal">Which of the fields that share the name; most names have one.</param>
    internal void Select(string? name, int index, int ordinal = 0) => Pick(name is null ? [] : [(name, index, ordinal)]);

    internal int PickedCount => _picked.Count;

    internal bool IsPicked(string name, int index, int ordinal) => _picked.Contains((name, index, ordinal));

    /// <summary>Picks the widgets, all on one page; the last one is the primary whose card and handles show.</summary>
    internal void Pick(IReadOnlyList<(string Name, int Index, int Ordinal)> widgets)
    {
        _picked = [.. widgets];
        (_selected, _selectedIndex, _selectedOrdinal) = widgets.Count == 0 ? (null, 0, 0) : widgets[^1];
        if (SelectedField(Form) is { Kind: FieldKind.Radio } radio) GroupBox.Text = radio.Name;
        ShowDesign(Form);
    }

    /// <summary>Adds the widget to the pick or takes it out; a widget of another page starts the pick again.</summary>
    internal void Toggle(string name, int index, int ordinal)
    {
        var key = (name, index, ordinal);
        int? page = Form.FindAll(name).ElementAtOrDefault(ordinal)?.Widgets.ElementAtOrDefault(index)?.PageIndex;
        bool elsewhere = SelectedBox() is { } primary && primary.Page != page;
        var kept = _picked.Where(k => k != key && !elsewhere).ToList();
        if (elsewhere || !_picked.Contains(key)) kept.Add(key);
        Pick(kept);
    }

    internal void PickIn(int page, Rect area) =>
        Pick([.. FormEdits.Widgets(Form, page, BoxOf).Where(w => w.Box.IntersectsWith(area)).Select(w => (w.Name, w.Index, w.Ordinal))]);

    private FormField? SelectedField(PdfForm form) => _selected is null ? null : form.FindAll(_selected).ElementAtOrDefault(_selectedOrdinal);

    internal (int Page, Rect Box)? SelectedBox()
    {
        if (SelectedField(Form)?.Widgets.ElementAtOrDefault(_selectedIndex) is not { PageIndex: >= 0 } widget) return null;
        return (widget.PageIndex, BoxOf(widget));
    }

    /// <summary>The field under a point of a page; the smallest wins, so a check box on a large text field can be picked.</summary>
    internal (string Name, int Index, int Ordinal, Rect Box)? WidgetAt(int page, Point point)
    {
        var hits = FormEdits.Widgets(Form, page, BoxOf).Where(w => w.Box.Contains(point)).ToList();
        return hits.Count == 0 ? null : hits.MinBy(w => w.Box.Width * w.Box.Height);
    }

    internal void Draw(int page, Rect box)
    {
        if (NewKind is not { } kind) return;
        var rect = UserRect(page, box);
        string? selected = _selected;
        string group = GroupBox.Text;
        int ordinal = _selectedOrdinal;
        var added = Edit<(string Name, int Widget)?>(Loc.T("Add form field"),
            form => FormEdits.Add(form, kind, page, rect, selected is null ? null : form.FindAll(selected).ElementAtOrDefault(ordinal), group));
        if (added is { } field) Select(field.Name, field.Widget, field.Name == selected ? ordinal : 0);
    }

    internal void Reshape(int page, Rect box)
    {
        if (_selected is null || SelectedField(Form) is null) return;
        var rect = UserRect(page, box);
        int index = _selectedIndex;
        ChangeField(Loc.T("Move form field"), (form, field) => form.Resize(field.Widgets[index], rect));
    }

    internal void ReshapeMany(int page, Vector offset)
    {
        var moves = new List<(string Name, int Index, int Ordinal, PdfRect Rect)>();
        foreach (var (name, index, ordinal) in _picked)
        {
            if (Form.FindAll(name).ElementAtOrDefault(ordinal)?.Widgets.ElementAtOrDefault(index) is not { } widget) return;
            var box = BoxOf(widget);
            box.Offset(offset);
            moves.Add((name, index, ordinal, UserRect(page, box)));
        }
        Edit(Loc.T("Move form fields"), form =>
        {
            FormEdits.ResizeAll(form, moves);
            return true;
        });
    }

    private Rect BoxOf(FormWidget widget)
    {
        var d = Viewer!.Geometry(widget.PageIndex).ToDisplay(widget.Rect);
        return new Rect(d.X, d.Y, d.Width, d.Height);
    }

    private PdfRect UserRect(int page, Rect box)
    {
        var size = Viewer!.PageSize(page);
        double x = Math.Clamp(box.X, 0, Math.Max(0, size.Width - box.Width));
        double y = Math.Clamp(box.Y, 0, Math.Max(0, size.Height - box.Height));
        return Viewer.Geometry(page).ToUser(new DisplayRect(x, y, Math.Min(box.Width, size.Width), Math.Min(box.Height, size.Height)));
    }

    private void ShowDesign(PdfForm form)
    {
        _frames!.Show(form, _picked, [.. _found.Where(f => f.IsChecked).Select(f => f.Proposal)]);
        ShowCard(form);
        ShowTabOrder();
        ShowPicked();
    }

    // The list follows the pick without moving the view.
    private void ShowPicked()
    {
        var rows = _rows.Where(r => _picked.Any(k => k.Name == r.Name && k.Ordinal == r.Ordinal)).ToList();
        if (rows.Count == FieldList.SelectedItems.Count && rows.All(FieldList.SelectedItems.Contains)) return;
        _loading = true;
        FieldList.SelectedItems.Clear();
        foreach (var row in rows) FieldList.SelectedItems.Add(row);
        _loading = false;
    }

    private void ShowCard(PdfForm form)
    {
        var field = SelectedField(form);
        bool many = _picked.Count > 1;
        Card.Visibility = field is null || many ? Visibility.Collapsed : Visibility.Visible;
        PickedText.Visibility = many ? Visibility.Visible : Visibility.Collapsed;
        if (many) PickedText.Text = Loc.Plural(_picked.Count, "{0} field selected", "{0} fields selected");
        if (field is null || many) return;
        bool text = field.Kind == FieldKind.Text;
        bool choice = field.Kind is FieldKind.ComboBox or FieldKind.ListBox;
        _loading = true;
        NameBox.Text = field.Name;
        HintBox.Text = field.Tooltip ?? "";
        RequiredBox.IsChecked = field.Has(FieldFlags.Required);
        ReadOnlyBox.IsChecked = field.Has(FieldFlags.ReadOnly);
        MultilineBox.IsChecked = field.Has(FieldFlags.Multiline);
        SecretBox.IsChecked = field.Has(FieldFlags.Password);
        LengthBox.Text = field.MaxLength > 0 ? field.MaxLength.ToString(CultureInfo.InvariantCulture) : "";
        ChoiceBox.Text = FormEdits.FormatOptions(field.Options);
        StartBox.Text = field.DefaultValue ?? "";
        MultiSelectBox.IsChecked = field.Has(FieldFlags.MultiSelect);
        EditableBox.IsChecked = field.Has(FieldFlags.Edit);
        CaptionBox.Text = field.Kind == FieldKind.PushButton ? FormEdits.CaptionOf(form, field) : "";
        _loading = false;
        MultiSelectBox.Visibility = field.Kind == FieldKind.ListBox ? Visibility.Visible : Visibility.Collapsed;
        EditableBox.Visibility = field.Kind == FieldKind.ComboBox ? Visibility.Visible : Visibility.Collapsed;
        CaptionRow.Visibility = field.Kind == FieldKind.PushButton ? Visibility.Visible : Visibility.Collapsed;
        MultilineBox.Visibility = SecretBox.Visibility = LengthRow.Visibility = text ? Visibility.Visible : Visibility.Collapsed;
        ChoiceRow.Visibility = choice ? Visibility.Visible : Visibility.Collapsed;
        StartRow.Visibility = text || choice ? Visibility.Visible : Visibility.Collapsed;
        ShowStyle(form, field);
    }

    private void ShowTabOrder()
    {
        if (Form.Document.Pages.Count == 0) return;
        _loading = true;
        var choices = (IReadOnlyList<TabChoice>)TabBox.ItemsSource;
        TabBox.SelectedItem = choices.FirstOrDefault(t => t.Order == Form.GetTabOrder(Viewer!.PageIndex)) ?? choices[0];
        _loading = false;
    }

    private void KindBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tab is null) return;
        GroupRow.Visibility = NewKind == FieldKind.Radio ? Visibility.Visible : Visibility.Collapsed;
        DrawHint.Text = NewKind == FieldKind.Radio
            ? Loc.T("Drag on the page to draw it. With a radio group selected the button joins it.")
            : Loc.T("Drag on the page to draw a field. Click a field to change it.");
    }

    private void TabBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || Tab is null || TabBox.SelectedItem is not TabChoice choice) return;
        int page = Viewer!.PageIndex;
        if (!Edit(Loc.T("Change tab order"), form => { form.SetTabOrder(page, choice.Order); return true; })) ShowTabOrder();
    }

    // The card writes a property when its box is left or Enter is pressed.
    private void Property_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Property_LostFocus(sender, e);
    }

    private void Property_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_loading || SelectedField(Form) is not { } field) return;
        bool done = true;
        if (LookProperty(sender, field) is { } styled) done = styled;
        else if (ReferenceEquals(sender, NameBox)) done = Rename(field, NameBox.Text.Trim());
        else if (ReferenceEquals(sender, HintBox) && HintBox.Text != (field.Tooltip ?? ""))
            done = ChangeField(Loc.T("Change field hint"), (form, f) => form.SetTooltip(f, HintBox.Text));
        else if (ReferenceEquals(sender, LengthBox))
        {
            string typed = LengthBox.Text.Trim();
            if (typed.Length > 0 && !int.TryParse(typed, NumberStyles.None, CultureInfo.InvariantCulture, out _))
            {
                Host!.ShowProblem(new Problem(Loc.T("Longest text not a number"), Loc.T("Type a whole number, or leave it empty for no limit.")));
                done = false;
            }
            else
            {
                int length = typed.Length == 0 ? 0 : int.Parse(typed, CultureInfo.InvariantCulture);
                if (length != field.MaxLength) done = ChangeField(Loc.T("Change longest text"), (form, f) => form.SetMaxLength(f, length));
            }
        }
        else if (ReferenceEquals(sender, ChoiceBox) && ChoiceBox.Text != FormEdits.FormatOptions(field.Options))
            done = ChangeField(Loc.T("Change choices"), (form, f) => form.SetOptions(f, FormEdits.ParseOptions(ChoiceBox.Text)));
        else if (ReferenceEquals(sender, CaptionBox) && CaptionBox.Text != FormEdits.CaptionOf(Form, field))
            done = ChangeField(Loc.T("Change button caption"), (form, f) => FormEdits.SetCaption(form, f, CaptionBox.Text));
        else if (ReferenceEquals(sender, StartBox) && StartBox.Text != (field.DefaultValue ?? ""))
            done = ChangeField(Loc.T("Change starting value"), (form, f) => form.SetDefaultValue(f, StartBox.Text.Length == 0 ? null : StartBox.Text));
        if (!done) ShowCard(Form);
    }

    private bool Rename(FormField field, string name)
    {
        if (name == field.Name) return true;
        if (name.Length == 0 || name.EndsWith('.'))
        {
            Host!.ShowProblem(new Problem(Loc.T("Field not changed"), FormText.BadName));
            return false;
        }
        if (!ChangeField(Loc.T("Rename field"), (form, f) => form.Rename(f, name))) return false;
        _selected = name;
        _selectedOrdinal = Form.FindAll(name).Count - 1;
        _picked = [(name, _selectedIndex, _selectedOrdinal)];
        if (SelectedField(Form) is { Kind: FieldKind.Radio } radio) GroupBox.Text = radio.Name;
        ShowDesign(Form);
        return true;
    }

    private void Flag_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is null) return;
        var (box, flag, label) =
            ReferenceEquals(sender, RequiredBox) ? (RequiredBox, FieldFlags.Required, Loc.T("Change required"))
            : ReferenceEquals(sender, ReadOnlyBox) ? (ReadOnlyBox, FieldFlags.ReadOnly, Loc.T("Change read only"))
            : ReferenceEquals(sender, MultilineBox) ? (MultilineBox, FieldFlags.Multiline, Loc.T("Change several lines"))
            : ReferenceEquals(sender, MultiSelectBox) ? (MultiSelectBox, FieldFlags.MultiSelect, Loc.T("Change several choices"))
            : ReferenceEquals(sender, EditableBox) ? (EditableBox, FieldFlags.Edit, Loc.T("Change typing in the list"))
            : (SecretBox, FieldFlags.Password, Loc.T("Change hidden text"));
        bool on = box.IsChecked == true;
        if (!ChangeField(label, (form, f) => form.SetFlag(f, flag, on))) ShowCard(Form);
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!Designing || !_canEdit || _working || _tool?.Dragging == true) return;
        if (Keyboard.FocusedElement is TextBox or ComboBox or PasswordBox) return;
        if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control)
            Pick([.. FormEdits.Widgets(Form, Viewer!.PageIndex, BoxOf).Select(w => (w.Name, w.Index, w.Ordinal))]);
        else if (e.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None && _picked.Count > 0) Select(null, 0);
        else if (e.Key == Key.Delete && Keyboard.Modifiers == ModifierKeys.None && _picked.Count > 0) Delete_Click(sender, e);
        else return;
        e.Handled = true;
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is null) return;
        if (_picked.Count > 1)
        {
            var picked = _picked.ToList();
            if (Edit(Loc.T("Delete form fields"), form =>
            {
                FormEdits.RemoveAll(form, picked);
                return true;
            })) Select(null, 0);
            return;
        }
        int index = _selectedIndex;
        // A radio button of a group of several goes alone; the last one takes the field with it.
        if (!ChangeField(Loc.T("Delete form field"), (form, field) =>
        {
            if (field.Widgets.Count > 1) form.Remove(field.Widgets[index]);
            else form.Remove(field);
        })) return;
        Select(null, 0);
    }

    private bool ChangeField(string label, Action<PdfForm, FormField> edit)
    {
        string name = _selected!;
        int ordinal = _selectedOrdinal;
        return Edit(label, form =>
        {
            edit(form, form.FindAll(name).ElementAtOrDefault(ordinal) ?? throw new InvalidOperationException(FormText.NotAField));
            return true;
        });
    }

    private async void Find_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        IReadOnlyList<FieldProposal>? found = null;
        await Host!.RunBusyAsync(Loc.T("Looking for fields"), async token =>
        {
            found = await Task.Run(() => FormEdits.Detect(tab, token), token).WaitAsync(token);
        });
        if (found is null || !ReferenceEquals(Tab, tab)) return;
        _found = [.. found.Select(p => new FoundRow(p))];
        FoundList.ItemsSource = _found;
        FoundText.Text = found.Count == 0
            ? Loc.T("No blanks found.")
            : Loc.Plural(found.Count, "{0} field found.", "{0} fields found.") + (found.Any(p => p.FromPixels) ? " " + Loc.T("Fields on scanned pages are guesses. Check each one.") : "");
        AddFoundButton.Visibility = FoundList.Visibility = found.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        FoundPane.Visibility = Visibility.Visible;
        ShowDesign(Form);
    }

    private void Found_Click(object sender, RoutedEventArgs e) => ShowDesign(Form);

    private void AddFound_Click(object sender, RoutedEventArgs e)
    {
        var chosen = _found.Where(f => f.IsChecked).Select(f => f.Proposal).ToList();
        if (chosen.Count == 0) return;
        if (Edit(Loc.T("Add form fields"), form => FormEdits.AddFound(form, chosen)) is not > 0) return;
        _found = [];
        FoundPane.Visibility = Visibility.Collapsed;
        ShowDesign(Form);
        Host!.SetStatus(Loc.Plural(chosen.Count, "Added {0} field.", "Added {0} fields."));
    }
}
