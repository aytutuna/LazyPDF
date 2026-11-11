using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

/// <summary>
/// Real controls over the fields of the pages in view. They live on the viewer's page overlays, so they follow
/// the page at any zoom and rotation. The page itself keeps showing each field as its appearance draws it.
/// </summary>
internal sealed partial class FillLayer
{
    private static readonly Brush Missing = new SolidColorBrush(Color.FromRgb(0xD1, 0x34, 0x38));

    private readonly IDocumentViewer _viewer;
    private readonly Func<string, string?, bool> _enter;
    private readonly Func<string, IReadOnlyList<string>, bool> _choose;
    private readonly Action<IReadOnlyList<string>?> _reset;
    private readonly Action<string> _sign;
    private readonly Action<string> _unsupported;
    private readonly Dictionary<int, (Canvas Host, List<Slot> Slots)> _pages = [];
    private PdfForm _form = null!;
    private bool _canFill;
    private bool _highlight;
    private int _key;

    /// <param name="enter">Takes a value typed or clicked into a field and says whether the field kept it.</param>
    /// <param name="choose">The same for the choices of a list box.</param>
    /// <param name="reset">Clears the named fields, or every field for null; what a Reset button on the page asks for.</param>
    /// <param name="sign">Opens signing with the named empty signature field chosen.</param>
    public FillLayer(IDocumentViewer viewer, Func<string, string?, bool> enter, Func<string, IReadOnlyList<string>, bool> choose, Action<IReadOnlyList<string>?> reset, Action<string> sign, Action<string> unsupported)
    {
        _viewer = viewer;
        _enter = enter;
        _choose = choose;
        _reset = reset;
        _sign = sign;
        _unsupported = unsupported;
    }

    public bool Highlight
    {
        get => _highlight;
        set
        {
            _highlight = value;
            foreach (var slot in _pages.Values.SelectMany(p => p.Slots)) Decorate(slot);
        }
    }

    /// <summary>Shows the form. Controls are kept while the fields stay as they are, so a field being typed in is not disturbed.</summary>
    public void Show(PdfForm form, bool canFill)
    {
        _form = form;
        _canFill = canFill;
        int key = Fingerprint(form, canFill);
        if (key != _key)
        {
            var focused = FocusedSlot();
            Drop();
            _key = key;
            Build();
            if (focused is not null) Focus(focused.Name, focused.Index);
            return;
        }
        foreach (var slot in _pages.Values.SelectMany(p => p.Slots))
        {
            if (form.Find(slot.Name) is { } field && slot.Index < field.Widgets.Count)
            {
                slot.Update(field, slot.Index);
                slot.Missing = IsMissing(field);
            }
            Decorate(slot);
        }
    }

    /// <summary>Builds the controls of pages that came into view.</summary>
    public void Follow()
    {
        if (_form is not null) Build();
    }

    public void Clear()
    {
        Drop();
        _form = null!;
    }

    /// <summary>Hands in what is typed in the control that has the keyboard, for a command that reads the file before the control loses it.</summary>
    public void Flush() => FocusedSlot()?.Flush?.Invoke();

    private void Drop()
    {
        foreach (var (page, (host, _)) in _pages) _viewer.Overlay(page).Children.Remove(host);
        _pages.Clear();
        _key = 0;
    }

    /// <summary>Puts the keyboard in the control of a widget; false when it has none.</summary>
    public bool Focus(string name, int index)
    {
        if (_form.Find(name)?.Widgets.ElementAtOrDefault(index) is not { } widget) return false;
        Add(widget.PageIndex);
        var slot = _pages[widget.PageIndex].Slots.FirstOrDefault(s => s.Name == name && s.Index == index);
        return slot?.Control?.Focus() ?? false;
    }

    private Slot? FocusedSlot() => _pages.Values.SelectMany(p => p.Slots).FirstOrDefault(s => s.Control is { IsKeyboardFocusWithin: true });

    private void Build()
    {
        foreach (int page in _viewer.VisiblePages) Add(page);
    }

    private void Add(int page)
    {
        if (_pages.ContainsKey(page)) return;
        var host = new Canvas();
        var slots = new List<Slot>();
        // The page's tab order is the order the controls are added in.
        foreach (var widget in _form.TabSequence(page))
        {
            if (Hidden(widget) || Make(widget) is not { } slot) continue;
            slots.Add(slot);
            Canvas.SetLeft(slot.Frame, slot.Box.X);
            Canvas.SetTop(slot.Frame, slot.Box.Y);
            slot.Frame.Width = slot.Box.Width;
            slot.Frame.Height = slot.Box.Height;
            Decorate(slot);
            slot.Frame.GotKeyboardFocus += (_, _) =>
            {
                if (Mouse.LeftButton != MouseButtonState.Pressed) _viewer.Reveal(page, slot.Box);
            };
            slot.Frame.PreviewKeyDown += (_, e) =>
            {
                bool shift = Keyboard.Modifiers == ModifierKeys.Shift;
                if (e.Key == Key.Tab && (shift || Keyboard.Modifiers == ModifierKeys.None) && Cross(page, slot, shift ? -1 : 1)) e.Handled = true;
            };
            host.Children.Add(slot.Frame);
        }
        _pages[page] = (host, slots);
        _viewer.Overlay(page).Children.Add(host);
    }

    // A page keeps its own tab order, so the last control of a page hands the keyboard to the first one of the next page that has any.
    private bool Cross(int page, Slot slot, int step)
    {
        var own = _pages[page].Slots.Where(s => s.Control is { IsEnabled: true }).ToList();
        if (own.Count == 0 || own[step > 0 ? ^1 : 0] != slot) return false;
        for (int next = page + step; next >= 0 && next < _viewer.PageCount; next += step)
        {
            Add(next);
            var there = _pages[next].Slots.Where(s => s.Control is { IsEnabled: true }).ToList();
            if (there.Count > 0) return (step > 0 ? there[0] : there[^1]).Control!.Focus();
        }
        return false;
    }

    private Slot? Make(FormWidget widget)
    {
        var field = widget.Field;
        var d = _viewer.Geometry(widget.PageIndex).ToDisplay(widget.Rect);
        var box = new Rect(d.X, d.Y, d.Width, d.Height);
        int index = IndexOf(field, widget);
        var slot = field.Kind switch
        {
            FieldKind.Text => field.Has(FieldFlags.Password) ? Password(field, index, box) : Text(field, index, box),
            FieldKind.CheckBox or FieldKind.Radio => Toggle(field, index, box),
            FieldKind.ComboBox => Combo(field, index, box),
            FieldKind.ListBox => List(field, index, box),
            FieldKind.PushButton => Push(field, index, box, widget),
            FieldKind.Signature => field.IsSigned ? new Slot(field.Name, index, box, null, (_, _) => { }) : Sign(field, index, box),
            _ => null,
        };
        if (slot is null) return null;
        slot.Missing = IsMissing(field);
        if (slot.Control is { } control)
        {
            string name = field.Tooltip is { Length: > 0 } tip ? tip : field.Name;
            System.Windows.Automation.AutomationProperties.SetName(control, name);
            control.ToolTip = field.Tooltip is { Length: > 0 } ? field.Tooltip : field.Kind == FieldKind.Signature ? Loc.T("Click to sign") : null;
            control.IsEnabled = _canFill && !field.Has(FieldFlags.ReadOnly);
        }
        return slot;
    }

    private void Decorate(Slot slot)
    {
        slot.Frame.Background = _highlight ? (Brush)Application.Current.FindResource("MarqueeFillBrush") : null;
        slot.Frame.BorderBrush = slot.Missing ? Missing : null;
    }

    private static bool IsMissing(FormField field) =>
        field.Has(FieldFlags.Required) && (string.IsNullOrEmpty(field.Value) || field.Value == "Off");

    private static bool Hidden(FormWidget widget) =>
        widget.Dictionary["F"] is PdfNumber { Value: var flags } && ((long)flags & 0b10_0010) != 0;

    private static int IndexOf(FormField field, FormWidget widget)
    {
        for (int i = 0; i < field.Widgets.Count; i++)
        {
            if (ReferenceEquals(field.Widgets[i].Dictionary, widget.Dictionary)) return i;
        }
        return 0;
    }

    // Which fields there are and where decides whether the controls can stay.
    private static int Fingerprint(PdfForm form, bool canFill)
    {
        var hash = new HashCode();
        hash.Add(canFill);
        var pages = new SortedSet<int>();
        foreach (var field in form.Fields)
        {
            hash.Add(field.Name);
            hash.Add(field.Kind);
            hash.Add(field.Flags);
            foreach (var option in field.Options) hash.Add(option);
            foreach (var widget in field.Widgets)
            {
                if (field.Kind == FieldKind.PushButton) hash.Add(ActionKey(form.Document, widget));
                hash.Add(widget.Rect);
                hash.Add(widget.PageIndex);
                if (widget.PageIndex >= 0) pages.Add(widget.PageIndex);
            }
        }
        foreach (int page in pages)
        {
            hash.Add(form.Document.Pages[page].Rotate);
            hash.Add(form.GetTabOrder(page));
        }
        return hash.ToHashCode();
    }

    // Push() closes over its action, so a changed action needs new controls.
    private static string ActionKey(PdfDocument document, FormWidget widget) => PdfActions.Read(document, widget.Dictionary["A"]) switch
    {
        null => "",
        UriAction a => $"Uri {a.Uri}",
        GoToAction a => $"GoTo {a.Destination.PageIndex}",
        NamedAction a => $"Named {a.Name}",
        SubmitFormAction a => $"Submit {a.Url}",
        LaunchAction a => $"Launch {a.File}",
        ResetFormAction a => $"Reset {a.Flags} {string.Join('', a.Fields)}",
        var a => a.GetType().Name,
    };
}
