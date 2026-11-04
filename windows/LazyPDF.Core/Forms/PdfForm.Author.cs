using System.Globalization;

namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    // Keys that belong to the widget annotation rather than the field when the two are one dictionary.
    private static readonly string[] WidgetKeys = ["Type", "Subtype", "Rect", "F", "P", "MK", "AP", "AS", "BS", "Border", "H", "A", "OC", "StructParent"];
    private static readonly string[] InheritedKeys = ["FT", "Ff", "V", "DV", "DA", "Q", "MaxLen", "Opt"];

    private const FieldFlags KindFlags = FieldFlags.Radio | FieldFlags.PushButton | FieldFlags.Combo;

    /// <summary>
    /// Adds a field and its first widget to the page, with an appearance, and returns it. A name with
    /// periods puts the field under parents of those names, made as needed. Throws
    /// <see cref="ArgumentException"/> for a bad name, page or rectangle and <see cref="InvalidOperationException"/>
    /// for a name already in use.
    /// </summary>
    public FormField AddField(FieldSpec spec)
    {
        RequireFillable();
        var path = SplitName(spec.Name);
        EnsureFree(spec.Name);
        var page = PageAt(spec.PageIndex);
        if (spec.Rect.IsEmpty) throw new ArgumentException(FormText.BadRect, nameof(spec));
        var (parentRef, items) = Container(path, spec.Name);

        var flags = spec.Flags & ~KindFlags;
        flags |= spec.Kind switch
        {
            FieldKind.Radio => FieldFlags.Radio | FieldFlags.NoToggleToOff,
            FieldKind.PushButton => FieldFlags.PushButton,
            FieldKind.ComboBox => FieldFlags.Combo,
            _ => FieldFlags.None,
        };
        if (spec.Kind == FieldKind.Text && (spec.MaxLength <= 0 || flags.HasFlag(FieldFlags.Multiline) || flags.HasFlag(FieldFlags.Password) || flags.HasFlag(FieldFlags.FileSelect))) flags &= ~FieldFlags.Comb;

        var node = new PdfDictionary
        {
            ["FT"] = new PdfName(spec.Kind switch
            {
                FieldKind.Text => "Tx",
                FieldKind.CheckBox or FieldKind.Radio or FieldKind.PushButton => "Btn",
                FieldKind.ComboBox or FieldKind.ListBox => "Ch",
                _ => "Sig",
            }),
            ["T"] = PdfText.ToObject(path[^1]),
        };
        if (flags != FieldFlags.None) node["Ff"] = new PdfNumber((long)flags);
        if (spec.Kind != FieldKind.Signature)
        {
            string color = string.Join(' ', spec.TextColor.Select(n => new PdfNumber(n).Text));
            node["DA"] = PdfText.ToObject($"/{spec.Font} {new PdfNumber(spec.FontSize).Text} Tf {color} {(spec.TextColor.Length switch { 1 => "g", 4 => "k", _ => "rg" })}");
        }
        if (spec.Alignment is 1 or 2) node["Q"] = new PdfNumber(spec.Alignment);
        if (spec.Kind == FieldKind.Text && spec.MaxLength > 0) node["MaxLen"] = new PdfNumber(spec.MaxLength);
        if (spec.Options is { Count: > 0 } && spec.Kind is FieldKind.ComboBox or FieldKind.ListBox) node["Opt"] = OptionsObject(spec.Options);
        if (spec.Tooltip is { Length: > 0 }) node["TU"] = PdfText.ToObject(spec.Tooltip);
        if (spec.DefaultValue is { } dv) node["DV"] = spec.Kind is FieldKind.CheckBox or FieldKind.Radio ? new PdfName(dv) : PdfText.ToObject(dv);
        if (parentRef is not null) node["Parent"] = parentRef;

        var widget = spec.Kind == FieldKind.Radio ? new PdfDictionary() : node;
        FillWidget(widget, page, spec.Rect, spec);
        var nodeRef = _document.Add(node);
        PdfReference widgetRef = nodeRef;
        if (widget != node)
        {
            widget["Parent"] = nodeRef;
            widgetRef = _document.Add(widget);
            node["Kids"] = new PdfArray([widgetRef]);
        }
        items.Items.Add(nodeRef);
        AppendAnnotation(page, widgetRef);
        DropXfa();
        Refresh();

        var created = Find(spec.Name)!;
        Draw(created, spec.ExportValue ?? (spec.Kind == FieldKind.Radio ? "Choice1" : "Yes"), spec.Value);
        return Find(spec.Name)!;
    }

    /// <summary>
    /// Adds another widget to a field: a second place for the same text field, or the next button of a radio
    /// group (<paramref name="export"/> is what it stands for). It looks like the field's first widget.
    /// </summary>
    public FormWidget AddWidget(FormField field, int pageIndex, PdfRect rect, string? export = null)
    {
        RequireFillable();
        if (field.Reference is null) throw new InvalidOperationException(FormText.NotAField);
        var page = PageAt(pageIndex);
        if (rect.IsEmpty) throw new ArgumentException(FormText.BadRect, nameof(rect));
        if (field.Widgets.Count == 1 && ReferenceEquals(field.Widgets[0].Dictionary, field.Dictionary))
        {
            SplitWidget(field);
            field = Current(field.Dictionary)!;
        }

        var widget = new PdfDictionary { ["Parent"] = field.Reference };
        var first = field.Widgets.FirstOrDefault()?.Dictionary;
        foreach (string key in (ReadOnlySpan<string>)["MK", "BS", "Border"])
        {
            if (first?[key] is { } value) widget[key] = value is PdfDictionary d ? d.Copy() : value;
        }
        widget["Type"] = new PdfName("Annot");
        widget["Subtype"] = new PdfName("Widget");
        widget["Rect"] = rect.ToArray();
        widget["F"] = new PdfNumber(4);
        widget["P"] = page.Reference;
        var widgetRef = _document.Add(widget);
        if (_document.Array(field.Dictionary, "Kids") is { } kids) kids.Items.Add(widgetRef);
        else field.Dictionary["Kids"] = new PdfArray([widgetRef]);
        AppendAnnotation(page, widgetRef);
        DropXfa();
        Refresh();

        var current = Current(field.Dictionary)!;
        string state = export ?? (current.Kind == FieldKind.Radio ? FreeChoice(current) : current.Widgets[0].OnState ?? "Yes");
        Draw(current, state, null);
        return Current(field.Dictionary)!.Widgets.First(w => ReferenceEquals(w.Dictionary, widget));
    }

    /// <summary>Moves the widget by the offsets (points, y up) and draws it again.</summary>
    public void Move(FormWidget widget, double dx, double dy) =>
        Resize(widget, new PdfRect(widget.Rect.Left + dx, widget.Rect.Bottom + dy, widget.Rect.Right + dx, widget.Rect.Top + dy));

    /// <summary>Gives the widget a new rectangle and draws its appearance again at that size.</summary>
    public void Resize(FormWidget widget, PdfRect rect)
    {
        RequireFillable();
        if (rect.IsEmpty) throw new ArgumentException(FormText.BadRect, nameof(rect));
        widget.Dictionary["Rect"] = rect.ToArray();
        DropXfa();
        Regenerate([widget.Field]);
    }

    /// <summary>Takes one widget out; the field goes with its last one.</summary>
    public void Remove(FormWidget widget)
    {
        RequireFillable();
        var field = widget.Field;
        if (field.Widgets.Count <= 1 || ReferenceEquals(widget.Dictionary, field.Dictionary))
        {
            Remove(field);
            return;
        }
        TakeFromPages(widget);
        if (_document.Array(field.Dictionary, "Kids") is { } kids)
        {
            int at = kids.Items.FindIndex(i => ReferenceEquals(_document.Resolve(i), widget.Dictionary));
            kids.Items.RemoveAll(i => ReferenceEquals(_document.Resolve(i), widget.Dictionary));
            if (at >= 0 && field.Kind is FieldKind.Radio or FieldKind.CheckBox) PageCleanup.ForgetButton(_document, field.Dictionary, at, widget.Dictionary);
        }
        if (widget.Reference is { } reference) _document.Delete(reference.Number);
        DropXfa();
        Refresh();
    }

    /// <summary>Takes the field out with its widgets, and the parents it leaves empty.</summary>
    public void Remove(FormField field)
    {
        RequireFillable();
        RemoveField(field);
        DropXfa();
        Refresh();
    }

    private void RemoveField(FormField field)
    {
        foreach (var widget in field.Widgets)
        {
            TakeFromPages(widget);
            if (widget.Reference is { } reference && !ReferenceEquals(widget.Dictionary, field.Dictionary)) _document.Delete(reference.Number);
        }
        RemoveFromCalculation(field.Dictionary, field.Reference);
        var (parent, taken) = Detach(field.Dictionary, field.Reference);
        Free(field.Reference ?? taken);
        Prune(parent);
    }

    /// <summary>Gives the field a new full name; a name with periods moves it under those parents.</summary>
    public void Rename(FormField field, string name)
    {
        RequireFillable();
        var path = SplitName(name);
        if (name != field.Name) EnsureFree(name);
        var d = field.Dictionary;
        string oldParentName = field.Name.Contains('.') ? field.Name[..field.Name.LastIndexOf('.')] : "";
        if (string.Join('.', path[..^1]) != oldParentName)
        {
            foreach (string key in InheritedKeys)
            {
                if (!d.ContainsKey(key) && Inherited(d, Ancestors(d), key) is { } value) d[key] = value;
            }
            var (parent, taken) = Detach(d);
            var (parentRef, items) = Container(path, name);
            items.Items.Add(field.Reference ?? taken ?? throw new InvalidOperationException(FormText.NotAField));
            if (parentRef is not null) d["Parent"] = parentRef;
            else d.Remove("Parent");
            Prune(parent);
        }
        d["T"] = PdfText.ToObject(path[^1]);
        DropXfa();
        Refresh();
    }

    /// <summary>Sets or clears one of the field's flag bits. The bits that name the kind (radio, push button, combo) cannot be changed.</summary>
    public void SetFlag(FormField field, FieldFlags flag, bool on)
    {
        RequireFillable();
        if ((flag & KindFlags) != 0) throw new ArgumentException("The kind of a field cannot be changed.", nameof(flag));
        var flags = on ? field.Flags | flag : field.Flags & ~flag;
        Store(field.Dictionary, "Ff", flags == FieldFlags.None ? null : new PdfNumber((long)flags), new PdfNumber(0));
        Regenerate([field]);
    }

    public void SetTooltip(FormField field, string? tooltip)
    {
        if (string.IsNullOrEmpty(tooltip)) field.Dictionary.Remove("TU");
        else field.Dictionary["TU"] = PdfText.ToObject(tooltip);
        Refresh();
    }

    /// <summary>Sets /DV; for a check box or radio group it is the name of the default state.</summary>
    public void SetDefaultValue(FormField field, string? value)
    {
        Store(field.Dictionary, "DV", string.IsNullOrEmpty(value) ? null
            : field.Kind is FieldKind.CheckBox or FieldKind.Radio ? new PdfName(value) : PdfText.ToObject(value), PdfText.ToObject(""));
        Refresh();
    }

    /// <summary>Replaces the choices of a combo or list box and draws it again. Selected values that are no longer offered stay in /V.</summary>
    public void SetOptions(FormField field, IReadOnlyList<FieldOption> options)
    {
        RequireFillable();
        if (field.Kind is not (FieldKind.ComboBox or FieldKind.ListBox)) throw new ArgumentException("Only a combo box or list box has options.", nameof(field));
        field.Dictionary["Opt"] = OptionsObject(options);
        field.Dictionary.Remove("I");
        Regenerate([field]);
    }

    public void SetMaxLength(FormField field, int length)
    {
        RequireFillable();
        Store(field.Dictionary, "MaxLen", length > 0 ? new PdfNumber(length) : null, new PdfNumber(0));
        Regenerate([field]);
    }

    // Removing a key hands the value back to an ancestor that has one, so an empty value is written then.
    private void Store(PdfDictionary d, string key, PdfObject? value, PdfObject empty)
    {
        if (value is not null) d[key] = value;
        else if (Ancestors(d).Any(a => Present(a[key]) is not null)) d[key] = empty;
        else d.Remove(key);
    }

    private static PdfArray OptionsObject(IReadOnlyList<FieldOption> options) =>
        new([.. options.Select(o => o.Export == o.Display ? (PdfObject)PdfText.ToObject(o.Export) : new PdfArray([PdfText.ToObject(o.Export), PdfText.ToObject(o.Display)]))]);

    private static string[] SplitName(string name)
    {
        var path = name.Split('.');
        if (path.Any(p => p.Length == 0)) throw new ArgumentException(FormText.BadName, nameof(name));
        return path;
    }

    private void EnsureFree(string name)
    {
        if (_fields.Any(f => f.Name == name || f.Name.StartsWith(name + ".", StringComparison.Ordinal) || name.StartsWith(f.Name + ".", StringComparison.Ordinal)))
        {
            throw new InvalidOperationException(FormText.NameTaken(name));
        }
    }

    private PdfPage PageAt(int index) =>
        index >= 0 && index < _document.Pages.Count ? _document.Pages[index] : throw new ArgumentException(FormText.NoPage, nameof(index));

    // The array the new field goes in, with the parents on the way made if they are not there yet.
    private (PdfReference? ParentRef, PdfArray Items) Container(string[] path, string fullName)
    {
        var acro = EnsureAcroForm();
        if (_document.Array(acro, "Fields") is not { } items) acro["Fields"] = items = new PdfArray([]);
        PdfReference? parentRef = null;
        for (int i = 0; i < path.Length - 1; i++)
        {
            int at = items.Items.FindIndex(it => _document.Resolve(it) is PdfDictionary d && PdfText.Read(_document, d, "T") == path[i]);
            PdfDictionary node;
            if (at < 0)
            {
                node = new PdfDictionary { ["T"] = PdfText.ToObject(path[i]), ["Kids"] = new PdfArray([]) };
                if (parentRef is not null) node["Parent"] = parentRef;
                parentRef = _document.Add(node);
                items.Items.Add(parentRef);
            }
            else
            {
                node = (PdfDictionary)_document.Resolve(items.Items[at])!;
                if (_document.Array(node, "Kids") is null) throw new InvalidOperationException(FormText.NameTaken(fullName));
                if (items.Items[at] is not PdfReference existing) items.Items[at] = existing = _document.Add(node);
                parentRef = existing;
            }
            items = _document.Array(node, "Kids")!;
        }
        return (parentRef, items);
    }

    private void FillWidget(PdfDictionary widget, PdfPage page, PdfRect rect, FieldSpec spec)
    {
        widget["Type"] = new PdfName("Annot");
        widget["Subtype"] = new PdfName("Widget");
        widget["Rect"] = rect.ToArray();
        widget["F"] = new PdfNumber(4);
        widget["P"] = page.Reference;
        var mk = new PdfDictionary();
        if (spec.Rotation % 360 is 90 or 180 or 270) mk["R"] = new PdfNumber(spec.Rotation % 360);
        if (spec.BorderColor is { Length: 1 or 3 or 4 } border) mk["BC"] = Numbers(border);
        if (spec.Background is { Length: 1 or 3 or 4 } background) mk["BG"] = Numbers(background);
        if (spec.Caption is { Length: > 0 }) mk["CA"] = PdfText.ToObject(spec.Caption);
        if (mk.Count > 0) widget["MK"] = mk;
        if (spec.BorderColor is not null)
        {
            var bs = new PdfDictionary
            {
                ["Type"] = new PdfName("Border"),
                ["W"] = new PdfNumber(spec.BorderWidth),
                ["S"] = new PdfName(spec.BorderStyle switch { BorderStyle.Dashed => "D", BorderStyle.Beveled => "B", BorderStyle.Inset => "I", BorderStyle.Underline => "U", _ => "S" }),
            };
            if (spec.BorderStyle == BorderStyle.Dashed) bs["D"] = new PdfArray([new PdfNumber(3)]);
            widget["BS"] = bs;
        }
    }

    private static PdfArray Numbers(double[] values) => new([.. values.Select(n => (PdfObject)new PdfNumber(n))]);

    private void AppendAnnotation(PdfPage page, PdfReference widget)
    {
        if (_document.Array(page.Dictionary, "Annots") is { } annots) annots.Items.Add(widget);
        else page.Dictionary["Annots"] = new PdfArray([widget]);
    }

    // Gives a new field its appearance, and its first value if it has one.
    private void Draw(FormField field, string state, string? value)
    {
        if (field.Kind is FieldKind.CheckBox or FieldKind.Radio)
        {
            var appearance = new FormAppearance(_document);
            foreach (var widget in field.Widgets.Where(w => w.OnState is null))
            {
                appearance.Apply(field, widget, null, "", onState: state);
                widget.Dictionary["AS"] = new PdfName("Off");
            }
            Refresh();
            if (value is not null && Current(field.Dictionary) is { } current && Prepare(current, Parts(current, value)) is { } change) Commit([change]);
            return;
        }
        if (value is not null && field.Kind != FieldKind.Signature && Prepare(field, Parts(field, value)) is { } change2) Commit([change2]);
        else Regenerate([field]);
    }

    // The widget's keys move to a dictionary of their own, so that the field can have several.
    private void SplitWidget(FormField field)
    {
        var d = field.Dictionary;
        var widget = new PdfDictionary();
        foreach (string key in WidgetKeys)
        {
            if (d[key] is not { } value) continue;
            widget[key] = value;
            d.Remove(key);
        }
        widget["Parent"] = field.Reference!;
        var widgetRef = _document.Add(widget);
        d["Kids"] = new PdfArray([widgetRef]);
        foreach (var page in _document.Pages)
        {
            if (_document.Array(page.Dictionary, "Annots") is { } annots)
            {
                for (int i = 0; i < annots.Items.Count; i++)
                {
                    if (ReferenceEquals(_document.Resolve(annots.Items[i]), d)) annots.Items[i] = widgetRef;
                }
            }
        }
        Refresh();
    }

    // The first ChoiceN that no button of the group has, so that a removal does not make two buttons share a state.
    private static string FreeChoice(FormField group)
    {
        var used = group.Widgets.Select(w => w.OnState).ToHashSet();
        int n = 1;
        while (used.Contains("Choice" + n.ToString(CultureInfo.InvariantCulture))) n++;
        return "Choice" + n.ToString(CultureInfo.InvariantCulture);
    }

    private void TakeFromPages(FormWidget widget)
    {
        var pages = widget.PageIndex >= 0 ? [_document.Pages[widget.PageIndex]] : _document.Pages;
        foreach (var page in pages)
        {
            if (_document.Array(page.Dictionary, "Annots") is { } annots)
            {
                annots.Items.RemoveAll(i => ReferenceEquals(_document.Resolve(i), widget.Dictionary));
            }
        }
    }

    // Takes the node out of the array that holds it and gives that array's owner back, with the reference it was listed by.
    // The reference is also matched by number, for a node an earlier step has already freed.
    private (PdfDictionary? Parent, PdfReference? Taken) Detach(PdfDictionary node, PdfReference? known = null)
    {
        var parent = _document.Dict(node, "Parent");
        var items = parent is not null ? _document.Array(parent, "Kids") : _document.Array(AcroForm, "Fields");
        bool Is(PdfObject i) => ReferenceEquals(_document.Resolve(i), node) || (known is not null && i is PdfReference r && r.Number == known.Number);
        PdfReference? taken = items?.Items.OfType<PdfReference>().FirstOrDefault(Is);
        items?.Items.RemoveAll(i => Is(i));
        return (parent, taken);
    }

    // A parent left without kids goes too, and so on up.
    private void Prune(PdfDictionary? node)
    {
        while (node is not null && _document.Array(node, "Kids") is { Items.Count: 0 })
        {
            RemoveFromCalculation(node);
            var (up, taken) = Detach(node);
            Free(taken);
            node = up;
        }
    }

    private void Free(PdfReference? reference)
    {
        if (reference is not null) _document.Delete(reference.Number);
    }

    private void RemoveFromCalculation(PdfDictionary node, PdfReference? known = null)
    {
        if (_document.Array(AcroForm, "CO") is { } order)
            order.Items.RemoveAll(i => ReferenceEquals(_document.Resolve(i), node) || (known is not null && i is PdfReference r && r.Number == known.Number));
    }

    private List<PdfDictionary> Ancestors(PdfDictionary node)
    {
        var chain = new List<PdfDictionary>();
        for (var up = _document.Dict(node, "Parent"); up is not null && chain.Count < MaxDepth && !chain.Contains(up); up = _document.Dict(up, "Parent")) chain.Insert(0, up);
        return chain;
    }
}
