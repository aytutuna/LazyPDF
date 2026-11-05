// The card rows that set how a field looks and what a button does: export value, font, size, colour and action.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

public sealed partial class FormsPanel
{
    private static readonly FontChoice[] Fonts =
    [
        new("Helvetica", "Helv"), new("Helvetica Bold", "HeBo"), new("Times", "TiRo"), new("Times Bold", "TiBo"), new("Courier", "Cour"), new("Courier Bold", "CoBo"),
    ];

    private void FillStyleChoices()
    {
        FontBox.DisplayMemberPath = nameof(FontChoice.Text);
        FontBox.ItemsSource = Fonts;
        ColourBox.DisplayMemberPath = nameof(ColourChoice.Text);
        ColourBox.ItemsSource = new ColourChoice[]
        {
            new(Loc.T("Black"), [0]), new(Loc.T("Blue"), [0, 0, 1]), new(Loc.T("Red"), [1, 0, 0]), new(Loc.T("Green"), [0, 0.5, 0]), new(Loc.T("Grey"), [0.5]),
        };
        ActionBox.DisplayMemberPath = nameof(ActionChoice.Text);
        ActionBox.ItemsSource = new ActionChoice[]
        {
            new(Loc.T("No action"), ButtonActionKind.None),
            new(Loc.T("Open a link"), ButtonActionKind.OpenLink),
            new(Loc.T("Reset form"), ButtonActionKind.Reset),
            new(Loc.T("Send the form to an address"), ButtonActionKind.Submit),
            new(Loc.T("Show a field"), ButtonActionKind.Show),
            new(Loc.T("Hide a field"), ButtonActionKind.Hide),
        };
    }

    private void ShowStyle(PdfForm form, FormField field)
    {
        bool button = field.Kind is FieldKind.CheckBox or FieldKind.Radio;
        bool textual = field.Kind is FieldKind.Text or FieldKind.ComboBox or FieldKind.ListBox or FieldKind.PushButton;
        ExportRow.Visibility = button ? Visibility.Visible : Visibility.Collapsed;
        FontRow.Visibility = textual ? Visibility.Visible : Visibility.Collapsed;
        ColourRow.Visibility = field.Kind == FieldKind.Signature ? Visibility.Collapsed : Visibility.Visible;
        ActionRow.Visibility = field.Kind == FieldKind.PushButton ? Visibility.Visible : Visibility.Collapsed;
        _loading = true;
        ExportBox.Text = button ? field.Widgets.ElementAtOrDefault(_selectedIndex)?.Export ?? "" : "";
        var look = form.GetTextLook(field);
        FontBox.SelectedItem = Fonts.FirstOrDefault(f => f.Name == look.Font);
        SizeBox.Text = look.Size > 0 ? look.Size.ToString("0.##", CultureInfo.InvariantCulture) : "";
        ColourBox.SelectedItem = ((IEnumerable<ColourChoice>)ColourBox.ItemsSource).FirstOrDefault(c => FormEdits.SameColour(c.Rgb, look.Color));
        if (field.Kind == FieldKind.PushButton)
        {
            var action = form.GetButtonAction(field);
            ActionBox.SelectedItem = ((IEnumerable<ActionChoice>)ActionBox.ItemsSource).FirstOrDefault(a => a.Kind == action.Kind);
            TargetBox.Text = action.Target ?? "";
        }
        _loading = false;
        ShowTarget();
    }

    private void ShowTarget()
    {
        var kind = (ActionBox.SelectedItem as ActionChoice)?.Kind;
        TargetRow.Visibility = kind is { } k && NeedsTarget(k) ? Visibility.Visible : Visibility.Collapsed;
        TargetLabel.Text = IsFieldAction(kind.GetValueOrDefault()) ? Loc.T("Field name") : Loc.T("Address");
    }

    private static bool IsFieldAction(ButtonActionKind kind) => kind is ButtonActionKind.Show or ButtonActionKind.Hide;

    private static bool NeedsTarget(ButtonActionKind kind) => kind is ButtonActionKind.OpenLink or ButtonActionKind.Submit or ButtonActionKind.Show or ButtonActionKind.Hide;

    private void Look_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SelectedField(Form) is not { } field) return;
        var look = Form.GetTextLook(field);
        bool done = true;
        if (ReferenceEquals(sender, FontBox) && FontBox.SelectedItem is FontChoice font && font.Name != look.Font)
            done = ChangeField(Loc.T("Change font"), (form, f) => form.SetFont(f, font.Name));
        else if (ReferenceEquals(sender, ColourBox) && ColourBox.SelectedItem is ColourChoice colour && !FormEdits.SameColour(colour.Rgb, look.Color))
            done = ChangeField(Loc.T("Change text colour"), (form, f) => form.SetTextColor(f, colour.Rgb));
        if (!done) ShowCard(Form);
    }

    // A kind that needs an address or a field waits for it to be typed.
    private void Action_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ShowTarget();
        if (_loading || SelectedField(Form) is not { } field || ActionBox.SelectedItem is not ActionChoice choice) return;
        // An address is not a field name, so it does not carry over from one to the other.
        if (e.RemovedItems.OfType<ActionChoice>().FirstOrDefault() is { } previous && (!NeedsTarget(previous.Kind) || IsFieldAction(previous.Kind) != IsFieldAction(choice.Kind))) TargetBox.Text = "";
        if (choice.Kind != Form.GetButtonAction(field).Kind && (!NeedsTarget(choice.Kind) || TargetBox.Text.Trim().Length > 0)) SetAction(choice.Kind);
    }

    // Null when the sender is not one of these rows; otherwise whether the field kept the change.
    private bool? LookProperty(object sender, FormField field)
    {
        if (ReferenceEquals(sender, ExportBox))
        {
            string typed = ExportBox.Text.Trim();
            int index = _selectedIndex;
            if (typed == (field.Widgets.ElementAtOrDefault(index)?.Export ?? "")) return true;
            return ChangeField(Loc.T("Change export value"), (form, f) => form.SetExportValue(f.Widgets[index], typed));
        }
        if (ReferenceEquals(sender, SizeBox))
        {
            string typed = SizeBox.Text.Trim();
            double size = 0;
            if (typed.Length > 0 && !(double.TryParse(typed, NumberStyles.Float, CultureInfo.InvariantCulture, out size) && size is >= 0 and <= 200))
            {
                Host!.ShowProblem(new Problem(Loc.T("Text size not accepted"), Loc.T("Type a number from 0 to 200, or leave it empty to fit the text to the field.")));
                return false;
            }
            return size == Form.GetTextLook(field).Size || ChangeField(Loc.T("Change text size"), (form, f) => form.SetFontSize(f, size));
        }
        if (ReferenceEquals(sender, TargetBox))
        {
            var current = Form.GetButtonAction(field);
            string typed = TargetBox.Text.Trim();
            if (ActionBox.SelectedItem is not ActionChoice { Kind: var kind } || !NeedsTarget(kind) || typed.Length == 0) return true;
            return (kind == current.Kind && typed == current.Target) || SetAction(kind);
        }
        return null;
    }

    private bool SetAction(ButtonActionKind kind)
    {
        string target = TargetBox.Text.Trim();
        if (kind is ButtonActionKind.OpenLink or ButtonActionKind.Submit)
        {
            if (FormEdits.AddressOf(target) is not { } address)
            {
                Host!.ShowProblem(new Problem(Loc.T("Address not accepted"), Loc.T("Type a web address such as https://example.com.")));
                return false;
            }
            target = address;
        }
        bool done = ChangeField(Loc.T("Change button action"), (form, f) => form.SetButtonAction(f, new ButtonAction(kind, target)));
        if (!done) ShowCard(Form);
        return done;
    }
}
