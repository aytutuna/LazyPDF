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
    private const int Raised = 10;
    private int _styledFor;

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
            _styledFor = _viewer.Rotation;
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
        _styledFor = _viewer.Rotation;
    }

    /// <summary>Restyles the controls when the view was turned; scrolling and zooming do nothing here.</summary>
    public void Restyle()
    {
        if (_viewer.Rotation == _styledFor) return;
        _styledFor = _viewer.Rotation;
        foreach (var slot in _pages.Values.SelectMany(p => p.Slots)) Decorate(slot);
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
        foreach (var (page, (host, _)) in _pages)
        {
            var overlay = _viewer.Overlay(page);
            overlay.Children.Remove(host);
            overlay.ClearValue(Panel.ZIndexProperty);
        }
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
        var size = _viewer.PageSize(page);
        var host = new Canvas { Clip = new RectangleGeometry(new Rect(0, 0, size.Width, size.Height)) };
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
            slot.Frame.IsKeyboardFocusWithinChanged += (_, e) => Focused(page, host, slot, (bool)e.NewValue);
            if (slot.Turns)
            {
                // The turn happens when the keyboard arrives, so the press that would have clicked the sideways
                // control only focuses it; the next click lands on the control as it is then drawn.
                slot.Frame.PreviewMouseLeftButtonDown += (_, e) =>
                {
                    if (_viewer.Rotation == 0 || slot.Frame.IsKeyboardFocusWithin || slot.Control is not { IsEnabled: true }) return;
                    slot.Control.Focus();
                    e.Handled = true;
                };
            }
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

    // On a turned view the control being typed in is turned back and moved into the page, and drawn over its
    // neighbours (and over the next page's layer) while it has the keyboard. Only a transform, position and order
    // change, so nothing typed is lost and no text change is raised.
    private void Focused(int page, Canvas host, Slot slot, bool within)
    {
        int rotation = _viewer.Rotation;
        if (!within)
        {
            if (slot.Turned) Release(page, host, slot);
            return;
        }
        if (!slot.Turns || rotation == 0)
        {
            if (Mouse.LeftButton != MouseButtonState.Pressed) _viewer.Reveal(page, slot.Box);
            return;
        }
        var size = _viewer.PageSize(page);
        var placed = PageOverlay.Place(slot.Box, size, rotation);
        Canvas.SetLeft(slot.Frame, placed.X);
        Canvas.SetTop(slot.Frame, placed.Y);
        PageOverlay.KeepUpright(slot.Frame, rotation, slot.Box.Size);
        slot.Turned = true;
        host.Clip = null;
        Panel.SetZIndex(slot.Frame, Raised);
        Panel.SetZIndex(host, Raised);
        Panel.SetZIndex(_viewer.Overlay(page), Raised);
        _viewer.Reveal(page, PageOverlay.UprightBounds(placed, rotation));
    }

    private void Release(int page, Canvas host, Slot slot)
    {
        slot.Turned = false;
        slot.Frame.RenderTransform = null;
        Canvas.SetLeft(slot.Frame, slot.Box.X);
        Canvas.SetTop(slot.Frame, slot.Box.Y);
        slot.Frame.ClearValue(Panel.ZIndexProperty);
        // The host and the layer are shared by the page's slots, so they drop back only once none of them has the
        // keyboard. A host that was rebuilt since is no longer the page's; its replacement owns the layer now.
        if (!_pages.TryGetValue(page, out var current) || current.Host != host) return;
        if (current.Slots.Any(s => s.Control is { IsKeyboardFocusWithin: true })) return;
        var size = _viewer.PageSize(page);
        host.Clip = new RectangleGeometry(new Rect(0, 0, size.Width, size.Height));
        host.ClearValue(Panel.ZIndexProperty);
        _viewer.Overlay(page).ClearValue(Panel.ZIndexProperty);
    }

    // Tab goes by the page's own list, not the visual order: a raised control is the last child of its layer, so WPF
    // would skip its neighbours. The ends of a page hand the keyboard to the next page that has any.
    private bool Cross(int page, Slot slot, int step)
    {
        var own = _pages[page].Slots.Where(s => s.Control is { IsEnabled: true }).ToList();
        int at = own.IndexOf(slot);
        if (at < 0) return false;
        if (at + step >= 0 && at + step < own.Count) return own[at + step].Control!.Focus();
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
        slot.Turns = field.Kind is FieldKind.Text or FieldKind.ComboBox or FieldKind.ListBox;
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
        if (slot.Control is ComboBox or ListBox) slot.Control.Style = _viewer.Rotation == 0 ? null : FieldStyles.Idle(slot.Control);
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
