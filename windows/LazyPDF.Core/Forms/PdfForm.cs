namespace LazyPDF.Core;

/// <summary>
/// The AcroForm of a document (ISO 32000-1 12.7): its fields read with inheritance, filled, authored,
/// calculated and flattened. It works on the open <see cref="PdfDocument"/> in memory; the edit
/// session commits it. A field whose value changes always gets a new appearance stream, because the
/// system renderer ignores /NeedAppearances and keeps a stale /AP. Fields are read again after every
/// change made through this class; call <see cref="Refresh"/> after changing dictionaries by hand.
/// </summary>
public sealed partial class PdfForm
{
    internal const int MaxFields = 200_000;
    private const int MaxDepth = 32;

    private readonly PdfDocument _document;
    private readonly IFontSource? _fonts;
    private IReadOnlyList<FormField> _fields = [];
    private Dictionary<string, List<FormField>> _byName = [];
    private Dictionary<PdfDictionary, FormField> _byDictionary = new(ReferenceEqualityComparer.Instance);

    private PdfForm(PdfDocument document, IFontSource? fonts)
    {
        _document = document;
        _fonts = fonts;
    }

    /// <summary>
    /// Reads the form; a document without an /AcroForm gives an empty one. <paramref name="fonts"/> finds
    /// font files for text the form's own fonts cannot show (Turkish ğ, ş, ı in a Latin-1 font).
    /// </summary>
    public static PdfForm Read(PdfDocument document, IFontSource? fonts = null)
    {
        var form = new PdfForm(document, fonts);
        form.Refresh();
        return form;
    }

    public PdfDocument Document => _document;

    public PdfDictionary? AcroForm => _document.Dict(_document.Catalog, "AcroForm");

    /// <summary>Every field, orphans last. A radio group is one field with a widget per button.</summary>
    public IReadOnlyList<FormField> Fields => _fields;

    /// <summary>Widgets a page lists whose field is not reachable from /AcroForm /Fields.</summary>
    public IReadOnlyList<FormField> Orphans => [.. _fields.Where(f => f.IsOrphan)];

    /// <summary>/NeedAppearances is set: the file's maker says its appearances are stale.</summary>
    public bool NeedAppearances => _document.Bool(AcroForm, "NeedAppearances") == true;

    /// <summary>The XFA form behind the AcroForm, if any. Dynamic forms are refused by everything that changes the form.</summary>
    public XfaKind Xfa => !_document.HasXfa ? XfaKind.None : _fields.Count > 0 ? XfaKind.Static : XfaKind.Dynamic;

    /// <summary>The /XFA entry was taken out by a change to a static XFA form (see <see cref="FormText.XfaRemoved"/>).</summary>
    public bool XfaRemoved { get; private set; }

    /// <summary>False for an encrypted file opened with the user password whose permissions allow neither filling forms nor annotating; enforcing it is the app's call.</summary>
    public bool CanFill => _document.Security is not { } security || security.OpenedAsOwner
        || security.Permissions.HasFlag(PdfPermissions.FillForms) || security.Permissions.HasFlag(PdfPermissions.Annotate);

    public FormField? Find(string name) => _byName.TryGetValue(name, out var list) ? list[0] : null;

    /// <summary>All fields with the name: a name two fields share is one field to the user, and both change together.</summary>
    public IReadOnlyList<FormField> FindAll(string name) => _byName.TryGetValue(name, out var list) ? list : [];

    public void Refresh()
    {
        var pages = ScanWidgets();
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var fields = new List<FormField>();
        if (_document.Array(AcroForm, "Fields") is { } roots)
        {
            foreach (var item in roots.Items)
            {
                if (fields.Count >= MaxFields) break;
                Walk(item, [], seen, fields, pages);
            }
        }
        AddOrphans(pages, seen, fields);
        _fields = fields;
        _byName = [];
        _byDictionary = new(ReferenceEqualityComparer.Instance);
        foreach (var field in fields)
        {
            _byDictionary.TryAdd(field.Dictionary, field);
            if (!_byName.TryGetValue(field.Name, out var list)) _byName[field.Name] = list = [];
            list.Add(field);
        }
    }

    private sealed record Scanned(PdfDictionary Dictionary, PdfReference? Reference, int PageIndex);

    private sealed class WidgetScan
    {
        public List<Scanned> All { get; } = [];
        public Dictionary<PdfDictionary, int> PageOf { get; } = new(ReferenceEqualityComparer.Instance);
    }

    private WidgetScan ScanWidgets()
    {
        var scan = new WidgetScan();
        foreach (var page in _document.Pages)
        {
            if (_document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items.Take(PdfAnnotations.MaxAnnotations))
            {
                if (scan.All.Count >= MaxFields) return scan;
                if (_document.Resolve(item) is PdfDictionary d && _document.Name(d, "Subtype") == "Widget" && scan.PageOf.TryAdd(d, page.Index))
                {
                    scan.All.Add(new Scanned(d, item as PdfReference, page.Index));
                }
            }
        }
        return scan;
    }

    private void Walk(PdfObject? item, List<PdfDictionary> chain, HashSet<PdfDictionary> seen, List<FormField> fields, WidgetScan pages)
    {
        if (fields.Count >= MaxFields || chain.Count > MaxDepth) return;
        if (_document.Resolve(item) is not PdfDictionary node || !seen.Add(node)) return;

        var kids = KidsOf(node);
        var fieldKids = kids.Where(k => IsFieldNode(k.Dictionary)).ToList();
        if (fieldKids.Count > 0)
        {
            chain.Add(node);
            foreach (var kid in fieldKids) Walk(kid.Item, chain, seen, fields, pages);
            chain.RemoveAt(chain.Count - 1);
            return;
        }
        var widgets = kids.Select(k => (k.Item, k.Dictionary)).ToList();
        if (_document.Name(node, "Subtype") == "Widget") widgets.Insert(0, (item!, node));
        foreach (var (_, d) in widgets) seen.Add(d);
        if (Build(node, item as PdfReference, chain, widgets, pages, orphan: false) is { } field) fields.Add(field);
    }

    private List<(PdfObject Item, PdfDictionary Dictionary)> KidsOf(PdfDictionary node)
    {
        var kids = new List<(PdfObject, PdfDictionary)>();
        if (_document.Array(node, "Kids") is not { } array) return kids;
        foreach (var item in array.Items.Take(MaxFields))
        {
            if (_document.Resolve(item) is PdfDictionary d) kids.Add((item, d));
        }
        return kids;
    }

    private bool IsFieldNode(PdfDictionary d) =>
        d.ContainsKey("T") || (d.ContainsKey("Kids") && _document.Name(d, "Subtype") != "Widget");

    private void AddOrphans(WidgetScan pages, HashSet<PdfDictionary> seen, List<FormField> fields)
    {
        var groups = new Dictionary<PdfDictionary, (PdfReference? Reference, List<(PdfObject, PdfDictionary)> Widgets)>(ReferenceEqualityComparer.Instance);
        var order = new List<PdfDictionary>();
        foreach (var scanned in pages.All)
        {
            if (seen.Contains(scanned.Dictionary)) continue;
            var parent = _document.Dict(scanned.Dictionary, "Parent");
            var key = parent is not null && !scanned.Dictionary.ContainsKey("T") ? parent : scanned.Dictionary;
            if (!groups.TryGetValue(key, out var group))
            {
                var reference = ReferenceEquals(key, scanned.Dictionary) ? scanned.Reference : scanned.Dictionary["Parent"] as PdfReference;
                groups[key] = group = (reference, []);
                order.Add(key);
            }
            group.Widgets.Add((scanned.Reference ?? (PdfObject)scanned.Dictionary, scanned.Dictionary));
        }
        foreach (var key in order)
        {
            if (fields.Count >= MaxFields) return;
            var (reference, widgets) = groups[key];
            var chain = new List<PdfDictionary>();
            for (var up = _document.Dict(key, "Parent"); up is not null && chain.Count < MaxDepth && !chain.Contains(up); up = _document.Dict(up, "Parent")) chain.Insert(0, up);
            if (Build(key, reference, chain, widgets, pages, orphan: true) is { } field) fields.Add(field);
        }
    }

    private FormField? Build(PdfDictionary node, PdfReference? reference, List<PdfDictionary> chain, List<(PdfObject Item, PdfDictionary Dictionary)> widgets, WidgetScan pages, bool orphan)
    {
        if (_document.Resolve(Inherited(node, chain, "FT")) is not PdfName ft) return null;
        var flags = (FieldFlags)(((_document.Resolve(Inherited(node, chain, "Ff")) as PdfNumber)?.Integer ?? 0) & 0x7FFFFFFF);
        var kind = ft.Value switch
        {
            "Btn" => flags.HasFlag(FieldFlags.PushButton) ? FieldKind.PushButton : flags.HasFlag(FieldFlags.Radio) ? FieldKind.Radio : FieldKind.CheckBox,
            "Tx" => FieldKind.Text,
            "Ch" => flags.HasFlag(FieldFlags.Combo) ? FieldKind.ComboBox : FieldKind.ListBox,
            "Sig" => FieldKind.Signature,
            _ => (FieldKind?)null,
        };
        if (kind is not { } k) return null;

        var names = chain.Append(node).Select(d => PdfText.Read(_document, d, "T")).Where(t => t is not null).ToList();
        string partial = PdfText.Read(_document, node, "T") ?? "";
        var options = ReadOptions(Inherited(node, chain, "Opt"));
        var values = Strings(Inherited(node, chain, "V"));
        var acro = AcroForm;
        var field = new FormField(node, reference, string.Join('.', names), partial, k, flags)
        {
            Selected = k is FieldKind.ComboBox or FieldKind.ListBox ? values : [],
            DefaultValue = Strings(Inherited(node, chain, "DV")).FirstOrDefault(),
            DefaultAppearance = PdfText.Read(_document, Inherited(node, chain, "DA")) ?? PdfText.Read(_document, acro, "DA"),
            Alignment = (int)((_document.Resolve(Inherited(node, chain, "Q")) as PdfNumber)?.Integer ?? _document.Integer(acro, "Q") ?? 0),
            MaxLength = (int)Math.Clamp((_document.Resolve(Inherited(node, chain, "MaxLen")) as PdfNumber)?.Integer ?? 0, 0, int.MaxValue),
            Options = options,
            Tooltip = PdfText.Read(_document, node, "TU"),
            IsOrphan = orphan,
        };
        var built = new List<FormWidget>();
        foreach (var (item, d) in widgets)
        {
            string? on = OnStateOf(d);
            string? export = on;
            if (k == FieldKind.Radio && options.Count > built.Count) export = options[built.Count].Export;
            var rect = _document.Rect(d, "Rect") ?? new PdfRect(0, 0, 0, 0);
            built.Add(new FormWidget(d, item as PdfReference, pages.PageOf.GetValueOrDefault(d, -1), rect, on, export) { Field = field, IsOn = on is not null && _document.Name(d, "AS") == on });
        }
        field.Widgets = built;
        field.Value = ValueOf(k, values, built);
        return field;
    }

    private string? ValueOf(FieldKind kind, IReadOnlyList<string> values, List<FormWidget> widgets)
    {
        if (kind is FieldKind.CheckBox or FieldKind.Radio)
        {
            string? state = values.FirstOrDefault();
            if (string.IsNullOrEmpty(state))
            {
                state = widgets.Select(w => _document.Name(w.Dictionary, "AS")).FirstOrDefault(s => s is not null and not "Off");
            }
            if (string.IsNullOrEmpty(state) || state == "Off") return "Off";
            return widgets.FirstOrDefault(w => w.OnState == state)?.Export ?? state;
        }
        if (kind is FieldKind.PushButton or FieldKind.Signature) return null;
        return values.FirstOrDefault();
    }

    private PdfObject? Inherited(PdfDictionary node, List<PdfDictionary> chain, string key)
    {
        if (Present(node[key]) is { } own) return own;
        for (int i = chain.Count - 1; i >= 0; i--)
        {
            if (Present(chain[i][key]) is { } value) return value;
        }
        return null;
    }

    private PdfObject? Present(PdfObject? value) => _document.Resolve(value) is null or PdfNull ? null : value;

    private IReadOnlyList<string> Strings(PdfObject? value)
    {
        switch (_document.Resolve(value))
        {
            case PdfName n:
                return [n.Value];
            case PdfString or PdfStream:
                return PdfText.Read(_document, value) is { } text ? [text] : [];
            case PdfArray array:
                return [.. array.Items.Take(MaxFields).Select(i => PdfText.Read(_document, i) ?? (_document.Resolve(i) as PdfName)?.Value).OfType<string>()];
            default:
                return [];
        }
    }

    private IReadOnlyList<FieldOption> ReadOptions(PdfObject? value)
    {
        if (_document.Resolve(value) is not PdfArray array) return [];
        var options = new List<FieldOption>();
        foreach (var item in array.Items.Take(MaxFields))
        {
            if (_document.Resolve(item) is PdfArray { Items.Count: >= 2 } pair)
            {
                string export = PdfText.Read(_document, pair.Items[0]) ?? "";
                options.Add(new FieldOption(export, PdfText.Read(_document, pair.Items[1]) ?? export));
            }
            else if (PdfText.Read(_document, item) is { } text) options.Add(new FieldOption(text));
        }
        return options;
    }

    private string? OnStateOf(PdfDictionary widget)
    {
        if (_document.Dict(widget, "AP") is not { } ap) return null;
        foreach (string key in (ReadOnlySpan<string>)["N", "D"])
        {
            if (_document.Dict(ap, key) is not { } states) continue;
            foreach (var entry in states.Entries)
            {
                if (entry.Key != "Off") return entry.Key;
            }
        }
        return null;
    }
}
