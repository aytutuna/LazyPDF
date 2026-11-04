using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

// One control per kind of field. Each reports what the person did through _enter and _choose, and takes the
// field's state again through its slot's update when the file changed.
internal sealed partial class FillLayer
{
    private static readonly Regex DaSize = new(@"(\S+)\s+Tf", RegexOptions.Compiled);

    // The rows of a list box stay black on white whatever the theme, like the other controls over the page.
    private static readonly Lazy<Style> Compact = new(() =>
    {
        var style = new Style(typeof(ListBoxItem), (Style)Application.Current.FindResource(typeof(ListBoxItem)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(2, 0, 2, 0)));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
        return style;
    });

    private sealed class Slot
    {
        public Slot(string name, int index, Rect box, FrameworkElement? control, Action<FormField, int> update)
        {
            Name = name;
            Index = index;
            Box = box;
            Control = control;
            Update = update;
            Frame = new Border { BorderThickness = new Thickness(1.5), Child = control, IsHitTestVisible = control is not null };
        }

        public string Name { get; }
        public int Index { get; }
        public Rect Box { get; }
        public FrameworkElement? Control { get; }
        public Border Frame { get; }
        public Action<FormField, int> Update { get; }
        public bool Missing { get; set; }

        /// <summary>Hands in what was typed and not yet kept; null for a control that keeps each change at once.</summary>
        public Action? Flush { get; set; }
    }

    private Slot Text(FormField field, int index, Rect box)
    {
        bool multiline = field.Has(FieldFlags.Multiline);
        var text = new TextBox
        {
            Style = FieldStyles.Text,
            Text = field.Value ?? "",
            FontSize = FontSizeOf(field, box, multiline),
            TextAlignment = field.Alignment switch { 1 => System.Windows.TextAlignment.Center, 2 => System.Windows.TextAlignment.Right, _ => System.Windows.TextAlignment.Left },
            MaxLength = field.MaxLength,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
        };
        string last = text.Text;
        var slot = new Slot(field.Name, index, box, text, (f, _) =>
        {
            last = f.Value ?? "";
            if (!text.IsKeyboardFocused) text.Text = last;
        });
        void Commit()
        {
            if (text.Text == last) return;
            string typed = text.Text;
            if (_enter(slot.Name, typed)) last = typed;
            else text.Text = last;
        }
        slot.Flush = Commit;
        text.LostFocus += (_, _) => Commit();
        text.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !multiline) Commit();
            else if (e.Key == Key.Escape) text.Text = last;
            else return;
            e.Handled = true;
        };
        return slot;
    }

    private Slot Password(FormField field, int index, Rect box)
    {
        var password = new PasswordBox
        {
            Style = FieldStyles.Password,
            Password = field.Value ?? "",
            FontSize = FontSizeOf(field, box, false),
            MaxLength = field.MaxLength,
        };
        string last = password.Password;
        var slot = new Slot(field.Name, index, box, password, (f, _) =>
        {
            last = f.Value ?? "";
            if (!password.IsKeyboardFocused) password.Password = last;
        });
        void Commit()
        {
            if (password.Password == last) return;
            string typed = password.Password;
            if (_enter(slot.Name, typed)) last = typed;
            else password.Password = last;
        }
        slot.Flush = Commit;
        password.LostFocus += (_, _) => Commit();
        password.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            Commit();
            e.Handled = true;
        };
        return slot;
    }

    private Slot Toggle(FormField field, int index, Rect box)
    {
        var first = field.Widgets[index];
        bool radio = field.Kind == FieldKind.Radio;
        bool on = first.IsOn;
        var button = new ToggleButton { Style = FieldStyles.Hit, IsChecked = on };
        var slot = new Slot(field.Name, index, box, button, (f, i) =>
        {
            on = f.Widgets[i].IsOn;
            button.IsChecked = on;
        });
        button.Click += (_, _) =>
        {
            button.IsChecked = on;
            string? value = (radio, on) switch
            {
                (false, true) => "Off",
                (false, false) => first.OnState ?? "Yes",
                (true, true) => field.Has(FieldFlags.NoToggleToOff) ? null : "Off",
                _ => first.Export ?? first.OnState,
            };
            if (value is not null) _enter(slot.Name, value);
        };
        return slot;
    }

    // A button does what its action says when the viewer or this tool can do it; the rest stay as drawn.
    private Slot? Push(FormField field, int index, Rect box, FormWidget widget)
    {
        var action = PdfActions.Read(_form.Document, widget.Dictionary["A"]);
        if (action is not (GoToAction or UriAction or NamedAction or ResetFormAction)) return null;
        var button = new ToggleButton { Style = FieldStyles.Hit };
        button.Click += (_, _) =>
        {
            button.IsChecked = false;
            if (action is ResetFormAction reset)
            {
                IReadOnlyList<string>? names = reset.Fields.Count == 0 ? null
                    : (reset.Flags & 1) == 0 ? reset.Fields
                    : [.. _form.Fields.Select(f => f.Name).Distinct().Except(reset.Fields)];
                _reset(names);
            }
            else _viewer.FollowAction(action);
        };
        return new Slot(field.Name, index, box, button, (_, _) => { });
    }

    private Slot Combo(FormField field, int index, Rect box)
    {
        bool editable = field.Has(FieldFlags.Edit);
        var options = field.Options;
        var combo = new ComboBox
        {
            ItemsSource = options.Select(o => o.Display).ToList(),
            IsEditable = editable,
            MinHeight = 0,
            MinWidth = 0,
            Padding = new Thickness(2, 0, 2, 0),
            FontSize = FontSizeOf(field, box, false),
            Background = Brushes.White,
            Foreground = Brushes.Black,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        bool setting = false;
        string last = "";
        void Show(FormField f)
        {
            setting = true;
            last = f.Value ?? "";
            int at = options.ToList().FindIndex(o => o.Export == last);
            combo.SelectedIndex = at;
            if (at < 0 && editable) combo.Text = last;
            setting = false;
        }
        Show(field);
        var slot = new Slot(field.Name, index, box, combo, (f, _) => Show(f));
        combo.SelectionChanged += (_, _) =>
        {
            if (setting || combo.SelectedIndex < 0) return;
            string export = options[combo.SelectedIndex].Export;
            if (export != last && _enter(slot.Name, export)) last = export;
        };
        if (editable)
        {
            void Commit()
            {
                if (combo.SelectedIndex >= 0 || combo.Text == last) return;
                string typed = combo.Text;
                if (_enter(slot.Name, typed)) last = typed;
            }
            slot.Flush = Commit;
            combo.LostFocus += (_, _) => Commit();
        }
        return slot;
    }

    private Slot List(FormField field, int index, Rect box)
    {
        var options = field.Options;
        var list = new ListBox
        {
            ItemsSource = options.Select(o => o.Display).ToList(),
            SelectionMode = field.Has(FieldFlags.MultiSelect) ? SelectionMode.Extended : SelectionMode.Single,
            FontSize = FontSizeOf(field, box, true),
            Padding = new Thickness(0),
            Background = Brushes.White,
            Foreground = Brushes.Black,
            ItemContainerStyle = Compact.Value,
        };
        bool setting = false;
        void Show(FormField f)
        {
            setting = true;
            var picked = Enumerable.Range(0, options.Count).Where(i => f.Selected.Contains(options[i].Export) || f.Selected.Contains(options[i].Display)).ToList();
            if (list.SelectionMode == SelectionMode.Single)
            {
                list.SelectedIndex = picked.Count > 0 ? picked[0] : -1;
            }
            else
            {
                list.SelectedItems.Clear();
                foreach (int i in picked) list.SelectedItems.Add(list.Items[i]);
            }
            setting = false;
        }
        Show(field);
        var slot = new Slot(field.Name, index, box, list, (f, _) => Show(f));
        list.SelectionChanged += (_, _) =>
        {
            if (setting) return;
            var picked = list.SelectedItems.Cast<object>().Select(list.Items.IndexOf).Order().Select(i => options[i].Export).ToList();
            _choose(slot.Name, picked);
        };
        return slot;
    }

    // Size 0 in the field's /DA means fit the text to the field.
    private static double FontSizeOf(FormField field, Rect box, bool tall)
    {
        var match = DaSize.Match(field.DefaultAppearance ?? "");
        double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double size);
        return size is > 0 and <= 200 ? size : tall ? 12 : Math.Clamp(box.Height * 0.7, 4, 12);
    }
}
