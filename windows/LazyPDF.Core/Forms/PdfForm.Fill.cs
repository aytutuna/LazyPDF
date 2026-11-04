using System.Text.RegularExpressions;

namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    private static readonly string[] TrueWords = ["yes", "on", "true", "1", "x", "checked"];

    /// <summary>One field's new state: the values to store (a check box or radio group: the state name or "Off").</summary>
    private sealed record Change(FormField Field, IReadOnlyList<string> Values)
    {
        public FormFont? Font { get; set; }
    }

    /// <summary>
    /// Sets the field called <paramref name="name"/> and every field sharing the name. Text is stored
    /// as given (cut at /MaxLen); a combo box takes an export value or its display text; a check box
    /// takes an export value, or yes/no words for on and off; a radio group takes an export value or
    /// "Off"; a list with several choices takes them separated by ";". The appearances are drawn again
    /// and the calculation order runs. Throws <see cref="InvalidOperationException"/> when no font can
    /// draw the text and <see cref="PdfReadException"/> for a dynamic XFA form.
    /// </summary>
    public FormFillResult SetValue(string name, string? value) => SetValues([new(name, value)]);

    /// <summary>Sets many fields at once; Turkish text that needs an added font shares one font for the batch.</summary>
    public FormFillResult SetValues(IEnumerable<KeyValuePair<string, string?>> values) =>
        Fill(values.Select(v => (v.Key, v.Value, (IReadOnlyList<string>?)null)));

    /// <summary>Sets a list box or combo box to several choices (export values or display texts).</summary>
    public FormFillResult SetChoices(string name, IReadOnlyList<string> choices) => Fill([(name, null, choices)]);

    private FormFillResult Fill(IEnumerable<(string Name, string? Text, IReadOnlyList<string>? Choices)> entries)
    {
        RequireFillable();
        var unknown = new List<string>();
        var rejected = new List<string>();
        var plan = new List<Change>();
        foreach (var (name, text, choices) in entries)
        {
            var matches = FindAll(name);
            if (matches.Count == 0)
            {
                unknown.Add(name);
                continue;
            }
            foreach (var field in matches)
            {
                if (Prepare(field, choices ?? Parts(field, text)) is { } change) plan.Add(change);
                else rejected.Add(name);
            }
        }
        Commit(plan);
        var calculation = Recalculate();
        return new FormFillResult(plan.Count, unknown, [.. rejected.Distinct()], calculation.Changed, calculation.NotRun);
    }

    /// <summary>
    /// Puts the named field (all fields when null) back to its /DV, or to empty without one, and runs the
    /// calculation order. Buttons and signatures are left alone. Returns the number of fields reset.
    /// </summary>
    public int Reset(string? name = null)
    {
        RequireFillable();
        var plan = new List<Change>();
        foreach (var field in name is null ? _fields : FindAll(name))
        {
            if (field.Kind is FieldKind.PushButton or FieldKind.Signature) continue;
            var defaults = field.Kind is FieldKind.ListBox or FieldKind.ComboBox ? DefaultChoices(field) : field.DefaultValue is { } dv ? [dv] : [];
            if (Prepare(field, defaults, reset: true) is { } change) plan.Add(change);
        }
        Commit(plan);
        Recalculate();
        return plan.Count;
    }

    /// <summary>Draws the appearances of the fields again from their values: after the form's maker set /NeedAppearances, or after changing a field's look by hand.</summary>
    public void Regenerate(IEnumerable<FormField>? fields = null)
    {
        RequireFillable();
        var chosen = (fields ?? _fields).Where(f => f.Kind != FieldKind.Signature).ToList();
        var needs = FontNeeds(chosen.Select(f => (f, (IReadOnlyList<string>)ValuesOf(f))));
        var fonts = ResolveFonts(needs);
        var refreshed = chosen.Select(f => (f, fonts.GetValueOrDefault(FontKey(f)))).ToList();
        foreach (var (field, font) in refreshed)
        {
            if (font.Replaced) SetFontName(field, font.Font.Name);
        }
        Refresh();
        foreach (var (old, font) in refreshed)
        {
            var field = Current(old);
            if (field is not null) Redraw(field, font.Font);
        }
        DropXfa();
    }

    private static IReadOnlyList<string> Parts(FormField field, string? text) =>
        text is null ? [] : field.Kind == FieldKind.ListBox && field.Has(FieldFlags.MultiSelect)
            ? [.. text.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)] : [text];

    private IReadOnlyList<string> DefaultChoices(FormField field)
    {
        var dv = _document.Resolve(field.Dictionary["DV"]);
        return dv is PdfArray ? Strings(dv) : field.DefaultValue is { } one ? [one] : [];
    }

    private IReadOnlyList<string> ValuesOf(FormField field) => field.Kind is FieldKind.ListBox or FieldKind.ComboBox
        ? field.Selected : field.Value is { } v ? [v] : [];

    private Change? Prepare(FormField field, IReadOnlyList<string> values, bool reset = false)
    {
        string first = values.FirstOrDefault() ?? "";
        switch (field.Kind)
        {
            case FieldKind.Text:
                if (field.MaxLength > 0 && first.EnumerateRunes().Count() > field.MaxLength)
                {
                    first = string.Concat(first.EnumerateRunes().Take(field.MaxLength).Select(r => r.ToString()));
                }
                return new Change(field, first.Length == 0 ? [] : [first]);
            case FieldKind.ComboBox:
                string stored = field.Options.FirstOrDefault(o => o.Export == first) is not null ? first
                    : field.Options.FirstOrDefault(o => o.Display == first)?.Export ?? first;
                if (!reset && first.Length > 0 && !field.Has(FieldFlags.Edit) && field.Options.All(o => o.Export != stored)) return null;
                return new Change(field, stored.Length == 0 ? [] : [stored]);
            case FieldKind.ListBox:
                var chosen = values.Select(v => field.Options.FirstOrDefault(o => o.Export == v)?.Export ?? field.Options.FirstOrDefault(o => o.Display == v)?.Export)
                    .OfType<string>().Distinct().ToList();
                if (chosen.Count == 0 && values.Any(v => v.Length > 0) && !reset) return null;
                if (!field.Has(FieldFlags.MultiSelect)) chosen = [.. chosen.Take(1)];
                return new Change(field, chosen);
            case FieldKind.CheckBox or FieldKind.Radio:
                return StateFor(field, first, reset) is { } state ? new Change(field, [state]) : null;
            default:
                return null;
        }
    }

    // The appearance state a value stands for, or null when the field has no such button.
    private string? StateFor(FormField field, string value, bool reset)
    {
        if (value.Length == 0 || value == "Off") return "Off";
        for (int i = 0; i < field.Widgets.Count; i++)
        {
            var w = field.Widgets[i];
            if (value == w.Export || value == w.OnState || value == StateName(field, i)) return StateName(field, i);
        }
        if (reset || field.Kind != FieldKind.CheckBox) return reset ? "Off" : null;
        string word = value.ToLowerInvariant();
        if (TrueWords.Contains(word)) return field.Widgets.Count > 0 ? StateName(field, 0) : "Yes";
        return word is "no" or "off" or "false" or "0" ? "Off" : null;
    }

    private static string StateName(FormField field, int index)
    {
        var w = field.Widgets[index];
        return w.OnState ?? w.Export ?? (field.Kind == FieldKind.Radio ? index.ToString(System.Globalization.CultureInfo.InvariantCulture) : "Yes");
    }

    private void Commit(List<Change> plan)
    {
        if (plan.Count == 0) return;
        var needs = FontNeeds(plan.Select(c => (c.Field, c.Values)));
        var fonts = ResolveFonts(needs);
        foreach (var change in plan) change.Font = fonts.GetValueOrDefault(FontKey(change.Field)).Font;

        foreach (var change in plan)
        {
            SetStored(change);
            if (fonts.GetValueOrDefault(FontKey(change.Field)).Replaced) SetFontName(change.Field, change.Font!.Name);
        }
        Refresh();
        foreach (var change in plan)
        {
            if (Current(change.Field) is { } field && field.Kind is not (FieldKind.CheckBox or FieldKind.Radio)) Redraw(field, change.Font);
        }
        DropXfa();
    }

    private FormField? Current(FormField old) => Current(old.Dictionary);

    private void SetStored(Change change)
    {
        var field = change.Field;
        var d = field.Dictionary;
        switch (field.Kind)
        {
            case FieldKind.Text or FieldKind.ComboBox:
                if (change.Values.Count == 0) Clear(d);
                else d["V"] = PdfText.ToObject(change.Values[0]);
                d.Remove("RV");
                if (field.Kind == FieldKind.ComboBox) d.Remove("I");
                break;
            case FieldKind.ListBox:
                if (change.Values.Count == 0)
                {
                    Clear(d);
                    d.Remove("I");
                }
                else
                {
                    d["V"] = field.Has(FieldFlags.MultiSelect) ? new PdfArray([.. change.Values.Select(v => (PdfObject)PdfText.ToObject(v))]) : PdfText.ToObject(change.Values[0]);
                    var indexes = field.Options.Select((o, i) => (o, i)).Where(p => change.Values.Contains(p.o.Export)).Select(p => (PdfObject)new PdfNumber(p.i));
                    d["I"] = new PdfArray([.. indexes]);
                }
                break;
            default:
                SetButtons(field, change.Values[0]);
                break;
        }
    }

    private void SetButtons(FormField field, string state)
    {
        field.Dictionary["V"] = new PdfName(state);
        var look = new FormAppearance(_document);
        for (int i = 0; i < field.Widgets.Count; i++)
        {
            var w = field.Widgets[i];
            string own = StateName(field, i);
            if (!HasState(w, own)) look.Apply(field, w, null, "", onState: own);
            w.Dictionary["AS"] = new PdfName(state == own ? own : "Off");
        }
    }

    private bool HasState(FormWidget widget, string state) =>
        _document.Dict(_document.Dict(widget.Dictionary, "AP"), "N") is { } states && states.ContainsKey(state) && states.ContainsKey("Off");

    private void Clear(PdfDictionary d)
    {
        d.Remove("V");
        var up = _document.Dict(d, "Parent");
        for (int depth = 0; up is not null && depth < 64; depth++, up = _document.Dict(up, "Parent"))
        {
            if (up.ContainsKey("V"))
            {
                d["V"] = new PdfString([], false);
                return;
            }
        }
    }

    private void Redraw(FormField field, FormFont? font)
    {
        var appearance = new FormAppearance(_document);
        var (display, color) = DisplayOf(field);
        for (int i = 0; i < field.Widgets.Count; i++)
        {
            var w = field.Widgets[i];
            if (field.Kind is FieldKind.CheckBox or FieldKind.Radio)
            {
                string own = StateName(field, i);
                appearance.Apply(field, w, null, "", onState: own);
                w.Dictionary["AS"] = new PdfName(field.IsChecked && field.Value == (w.Export ?? own) ? own : "Off");
            }
            else appearance.Apply(field, w, WidgetFont(field, w, font, display), display, color);
        }
    }

    // A widget with a /DA of its own is set in the font that names, which can differ from its field's.
    private FormFont? WidgetFont(FormField field, FormWidget widget, FormFont? font, string display)
    {
        string? own = PdfText.Read(_document, widget.Dictionary, "DA") is { } da ? DefaultAppearance.Parse(da).Font : null;
        if (own is null || own == FontKey(field) || own == font?.Name) return font;
        var (resolved, replaced) = ResolveFonts(new() { [own] = field.Kind == FieldKind.ListBox ? [.. field.Options.Select(o => o.Display)] : [display] })[own];
        if (replaced) SetFontName(widget.Dictionary, PdfText.Read(_document, widget.Dictionary, "DA"), resolved.Name);
        return resolved;
    }

    // What a text field shows: its value through the format script, if it has one of the built-in ones.
    private (string Text, double[]? Color) DisplayOf(FormField field)
    {
        string raw = field.Kind == FieldKind.ComboBox ? field.Options.FirstOrDefault(o => o.Export == field.Value)?.Display ?? field.Value ?? "" : field.Value ?? "";
        if (field.Kind is FieldKind.Text or FieldKind.ComboBox && FormScripts.CallsOf(this, field, "F") is { } calls)
        {
            foreach (var call in calls)
            {
                if (FormFunctions.Format(call, raw) is { } formatted) return (formatted.Text, formatted.Color);
            }
        }
        return (raw, null);
    }

    private static string FontKey(FormField field) => DefaultAppearance.Parse(field.DefaultAppearance).Font ?? "Helv";

    private Dictionary<string, List<string>> FontNeeds(IEnumerable<(FormField Field, IReadOnlyList<string> Values)> items)
    {
        var needs = new Dictionary<string, List<string>>();
        foreach (var (field, values) in items)
        {
            if (field.Kind is FieldKind.CheckBox or FieldKind.Radio or FieldKind.Signature) continue;
            if (!needs.TryGetValue(FontKey(field), out var texts)) needs[FontKey(field)] = texts = [];
            switch (field.Kind)
            {
                case FieldKind.ListBox:
                    texts.AddRange(field.Options.Select(o => o.Display));
                    break;
                case FieldKind.PushButton:
                    texts.AddRange(PdfText.Read(_document, _document.Dict(field.Widgets.FirstOrDefault()?.Dictionary, "MK"), "CA") is { } caption ? [caption] : []);
                    break;
                case FieldKind.ComboBox:
                    string shown = values.FirstOrDefault() is { } v ? field.Options.FirstOrDefault(o => o.Export == v)?.Display ?? v : "";
                    texts.Add(FormatText(field, shown));
                    break;
                default:
                    if (!field.Has(FieldFlags.Password)) texts.Add(FormatText(field, values.FirstOrDefault() ?? ""));
                    break;
            }
        }
        return needs;
    }

    private string FormatText(FormField field, string raw)
    {
        if (FormScripts.CallsOf(this, field, "F") is { } calls)
        {
            foreach (var call in calls)
            {
                if (FormFunctions.Format(call, raw) is { } formatted) return formatted.Text;
            }
        }
        return raw;
    }

    // Each font name the fields use, kept if it shows all their text, else replaced by one added font for the whole group.
    private Dictionary<string, (FormFont Font, bool Replaced)> ResolveFonts(Dictionary<string, List<string>> needs)
    {
        var result = new Dictionary<string, (FormFont, bool)>();
        var resources = EnsureResources();
        foreach (var (name, texts) in needs)
        {
            var current = FormFont.FromResource(_document, name, resources);
            if (current is not null && texts.All(current.CanShow))
            {
                result[name] = (current, false);
                continue;
            }
            var (family, style) = current is null ? Known(name) : FormFont.FamilyOf(_document, resources, name);
            var embedder = new PdfFontEmbedder(_document, _fonts);
            var added = embedder.Add(family, style, texts) ?? embedder.Add("Helvetica", style, texts) ?? throw new InvalidOperationException(FormText.NoFont);
            // A name already taken (a Type0 subset that FromResource cannot read) keeps its font.
            if (current is null && !added.IsEmbedded && _document.Dict(resources, "Font")?.ContainsKey(name) != true)
            {
                _document.Dict(resources, "Font")![name] = added.Reference;
                result[name] = (FormFont.FromAdded(name, added), false);
            }
            else
            {
                string fresh = ContentResources.Add(_document, resources, "Font", added.Reference, "LzF");
                result[name] = (FormFont.FromAdded(fresh, added), true);
            }
        }
        return result;
    }

    private static (string Family, FontStyles Style) Known(string name)
    {
        var format = DefaultAppearance.FormatOf(name, TextFormat.Default);
        return (format.Family, format.Style);
    }

    private static void SetFontName(FormField field, string name) => SetFontName(field.Dictionary, field.DefaultAppearance, name);

    private static void SetFontName(PdfDictionary holder, string? current, string name)
    {
        string da = current ?? "/Helv 0 Tf 0 g";
        string updated = Regex.Replace(da, @"/[^\s/<>\[\]()]+(\s+[-+\d.]+\s+Tf)", $"/{name}$1");
        if (updated == da && !da.Contains("Tf")) updated = $"/{name} 0 Tf " + da;
        holder["DA"] = PdfText.ToObject(updated);
    }

    private PdfDictionary EnsureAcroForm()
    {
        if (AcroForm is { } existing) return existing;
        var acro = new PdfDictionary { ["Fields"] = new PdfArray([]), ["DA"] = PdfText.ToObject("/Helv 0 Tf 0 g") };
        _document.Catalog["AcroForm"] = _document.Add(acro);
        return acro;
    }

    private PdfDictionary EnsureResources()
    {
        var acro = EnsureAcroForm();
        if (_document.Dict(acro, "DR") is not { } resources) acro["DR"] = resources = new PdfDictionary();
        if (_document.Dict(resources, "Font") is null) resources["Font"] = new PdfDictionary();
        return resources;
    }

    private void RequireFillable()
    {
        if (Xfa == XfaKind.Dynamic) throw new PdfReadException(PdfReadProblem.Unsupported, FormText.DynamicXfa);
    }

    // A static XFA form keeps its own copy of the data, which a viewer shows in place of the AcroForm.
    private void DropXfa()
    {
        if (!_document.HasXfa || AcroForm is not { } acro) return;
        acro.Remove("XFA");
        _document.Catalog.Remove("NeedsRendering");
        XfaRemoved = true;
    }
}
