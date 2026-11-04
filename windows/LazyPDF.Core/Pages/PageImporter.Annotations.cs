using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

// Annotations and form fields of the pages being copied. Annotations are copied afresh for every
// page copy, even when the page is copied twice, because a copy of a form field must be its own field.
internal sealed partial class PageImporter
{
    private const int MaxFieldDepth = 32;
    private const int MaxActionChain = 32;
    private const int MaxActionNodes = 512;
    private int _actionNodes;

    private readonly Dictionary<int, PdfReference> _local = [];
    private readonly Dictionary<int, (PdfReference Ref, PdfArray Kids)> _fields = [];
    private DestContext? _names;
    private HashSet<string>? _rootNames;
    private bool _formMerged;
    private readonly List<(PdfDictionary Source, PdfDictionary Copy)> _fieldActions = [];
    private readonly Dictionary<string, string> _fontRenames = [];
    private readonly Dictionary<int, List<PdfReference>> _copies = [];
    private readonly Dictionary<PdfArray, FieldCopy> _groups = new(ReferenceEqualityComparer.Instance);

    // A field above widgets as copied: which of the source's kids came across, by position.
    private sealed record FieldCopy(PdfDictionary Source, PdfDictionary Copy, List<int> Positions);

    private void CopyAnnotations(PdfPage page, PdfReference pageRef, PdfDictionary dict)
    {
        if (_source.Resolve(page.Dictionary["Annots"]) is not PdfArray annots) return;
        _local.Clear();
        var items = new List<(PdfReference Source, PdfDictionary Dict)>();
        int direct = 0;
        foreach (var item in annots.Items)
        {
            if (item is PdfReference reference && _source.Resolve(reference) is PdfDictionary annotation) items.Add((reference, annotation));
            // No number to key it by, so a direct annotation gets a negative one that no object has.
            else if (item is PdfDictionary inline) items.Add((new PdfReference(--direct, 0), inline));
        }

        // The form's defaults come first: a font renamed there is renamed in the /DA of every field copied.
        if (!_same && items.Any(i => _source.Name(i.Dict, "Subtype") == "Widget")) TargetFields();

        // Popups go second: one stays only with the annotation that owns it.
        var made = new List<(PdfDictionary Source, PdfDictionary Copy, PdfReference Ref)>();
        foreach (bool popups in new[] { false, true })
        {
            foreach (var (source, annotation) in items)
            {
                bool popup = _source.Name(annotation, "Subtype") == "Popup";
                if (popup != popups || _local.ContainsKey(source.Number)) continue;
                if (popup ? annotation["Parent"] is not PdfReference owner || !_local.ContainsKey(owner.Number) : IsDeadLink(annotation)) continue;
                var copy = new PdfDictionary();
                var reference = _target.Add(copy);
                _local[source.Number] = reference;
                made.Add((annotation, copy, reference));
            }
        }
        var sources = new Dictionary<PdfDictionary, PdfReference>(ReferenceEqualityComparer.Instance);
        foreach (var (numbered, annotation) in items) sources.TryAdd(annotation, numbered);
        foreach (var (source, copy, reference) in made) FillAnnotation(source, copy, reference, pageRef, sources[source]);
        ResolveFieldActions();
        foreach (var (number, reference) in _local)
        {
            if (number > 0) Record(number, reference);
        }

        var kept = items.Where(i => _local.ContainsKey(i.Source.Number)).Select(i => (PdfObject)_local[i.Source.Number]).Distinct().ToList();
        if (kept.Count > 0) dict["Annots"] = new PdfArray(kept);
    }

    private void FillAnnotation(PdfDictionary source, PdfDictionary copy, PdfReference self, PdfReference pageRef, PdfReference sourceRef)
    {
        bool widget = _source.Name(source, "Subtype") == "Widget";
        foreach (var (key, value) in source.Entries)
        {
            if (!ReferenceEquals(source[key], value)) continue;
            PdfObject? item = key switch
            {
                "P" => pageRef,
                "StructParent" => null,
                "Parent" when widget => null,
                "Popup" or "Parent" or "IRT" => value is PdfReference r && _local.TryGetValue(r.Number, out var mapped) ? mapped : null,
                "Dest" => FixDestination(value),
                "A" => FixAction(value),
                "AA" => FixAdditional(value),
                "DA" => FixDefaultAppearance(value),
                _ => Copy(value),
            };
            if (item is not null and not PdfNull) copy.Add(key, item);
        }
        if (widget) AttachWidget(source, copy, self, sourceRef);
    }

    private bool IsDeadLink(PdfDictionary annotation)
    {
        if (_source.Name(annotation, "Subtype") != "Link") return false;
        if (annotation.ContainsKey("Dest") && FixDestination(annotation["Dest"]) is null) return true;
        return _source.Dict(annotation, "A") is { } action && _source.Name(action, "S") == "GoTo" && FixDestination(action["D"]) is null;
    }

    private PdfObject? FixAction(PdfObject value, int depth = 0)
    {
        if (depth == 0) _actionNodes = 0;
        if (_source.Resolve(value) is not PdfDictionary action || depth > MaxActionChain || ++_actionNodes > MaxActionNodes) return null;
        string? type = _source.Name(action, "S");
        var copy = new PdfDictionary();
        foreach (var (key, item) in action.Entries)
        {
            if (!ReferenceEquals(action[key], item)) continue;
            PdfObject? made = key switch
            {
                "D" when type == "GoTo" => FixDestination(item),
                "Next" => FixNext(item, depth),
                "Fields" or "T" when !_same && type is "SubmitForm" or "ResetForm" or "Hide" => null,
                _ => Copy(item),
            };
            if (made is null or PdfNull)
            {
                if (key == "D" && type == "GoTo") return null;
                continue;
            }
            copy.Add(key, made);
        }
        if (!_same && type is "SubmitForm" or "ResetForm" or "Hide") _fieldActions.Add((action, copy));
        return copy;
    }

    private PdfObject? FixNext(PdfObject value, int depth)
    {
        if (_source.Resolve(value) is PdfArray list)
        {
            var kept = list.Items.Take(MaxActionChain).Select(i => FixAction(i, depth + 1)).OfType<PdfObject>().ToList();
            return kept.Count == 0 ? null : new PdfArray(kept);
        }
        return FixAction(value, depth + 1);
    }

    private PdfObject? FixAdditional(PdfObject value)
    {
        if (_source.Resolve(value) is not PdfDictionary triggers) return null;
        var copy = new PdfDictionary();
        foreach (var (key, item) in triggers.Entries)
        {
            if (ReferenceEquals(triggers[key], item) && FixAction(item) is { } action) copy.Add(key, action);
        }
        return copy;
    }

    // Fields an action names are set once the fields of the page are copied: those that did not come across drop out of the list.
    private void ResolveFieldActions()
    {
        foreach (var (source, copy) in _fieldActions)
        {
            bool hide = _source.Name(source, "S") == "Hide";
            string key = hide ? "T" : "Fields";
            if (source[key] is not { } named) continue;
            var items = _source.Resolve(named) is PdfArray array ? array.Items : [named];
            var kept = new List<PdfObject>();
            foreach (var item in items)
            {
                if (item is PdfReference r) {
                    if (_fields.TryGetValue(r.Number, out var field)) kept.Add(field.Ref);
                    else if (_local.TryGetValue(r.Number, out var local)) kept.Add(local);
                }
                else if (item is PdfString) kept.Add(Copy(item));
            }
            copy[key] = new PdfArray(kept);
        }
        _fieldActions.Clear();
    }

    /// <summary>
    /// The destination for the copy: an explicit one pointing at a page that came across, a named one
    /// looked up in the source and made explicit. Null when it points at a page that did not.
    /// </summary>
    private PdfObject? FixDestination(PdfObject? value)
    {
        if (value is null) return null;
        if (_same) return Copy(value);
        var resolved = _source.Resolve(value);
        if (resolved is PdfName or PdfString) resolved = _source.Resolve(PageDestinations.Lookup(_source, _names ??= new DestContext(_source), value));
        if (resolved is PdfDictionary named) resolved = _source.Resolve(named["D"]);
        if (resolved is not PdfArray { Items.Count: > 0 } array) return null;
        if (array.Items[0] is PdfReference page && !_newPages.ContainsKey(page.Number)) return null;
        return Copy(array);
    }

    private void AttachWidget(PdfDictionary source, PdfDictionary copy, PdfReference self, PdfReference sourceRef)
    {
        if (source["Parent"] is PdfReference parentRef && _source.Resolve(parentRef) is PdfDictionary parentSource)
        {
            var parent = FieldNode(parentRef, 1);
            copy["Parent"] = parent.Ref;
            parent.Kids.Items.Add(self);
            int position = _source.Array(parentSource, "Kids")?.Items.FindIndex(k => k is PdfReference r && r.Number == sourceRef.Number) ?? -1;
            _groups[parent.Kids].Positions.Add(position);
        }
        else if (copy.ContainsKey("T") || copy.ContainsKey("FT"))
        {
            AddRoot(self, copy);
        }
        DropSignature(source, copy);
    }

    // A field above the widgets, made once per import and holding only the widgets that came across.
    private (PdfReference Ref, PdfArray Kids) FieldNode(PdfReference source, int depth)
    {
        if (_fields.TryGetValue(source.Number, out var known)) return known;
        var node = (PdfDictionary)_source.Resolve(source)!;
        var copy = new PdfDictionary();
        var kids = new PdfArray([]);
        var reference = _target.Add(copy);
        _fields[source.Number] = (reference, kids);
        foreach (var (key, value) in node.Entries)
        {
            if (key is "Kids" or "Parent" || !ReferenceEquals(node[key], value)) continue;
            var item = key switch { "AA" => FixAdditional(value), "DA" => FixDefaultAppearance(value), _ => Copy(value) };
            if (item is not (null or PdfNull)) copy.Add(key, item);
        }
        copy["Kids"] = kids;
        _groups[kids] = new FieldCopy(node, copy, []);
        Record(source.Number, reference);
        DropSignature(node, copy);
        if (node["Parent"] is PdfReference up && depth < MaxFieldDepth && _source.Resolve(up) is PdfDictionary)
        {
            var parent = FieldNode(up, depth + 1);
            copy["Parent"] = parent.Ref;
            parent.Kids.Items.Add(reference);
        }
        else
        {
            AddRoot(reference, copy);
        }
        return (reference, kids);
    }

    // What a copied signature field signed is not in the copy; the field keeps its look and loses the signature.
    private void DropSignature(PdfDictionary source, PdfDictionary copy)
    {
        var node = source;
        for (int depth = 0; node is not null && depth < MaxFieldDepth; depth++)
        {
            if (_source.Name(node, "FT") is { } type)
            {
                if (type == "Sig") copy.Remove("V");
                return;
            }
            node = _source.Dict(node, "Parent");
        }
    }

    private void AddRoot(PdfReference reference, PdfDictionary root)
    {
        var fields = TargetFields();
        _rootNames ??= RootNames(fields);
        if (root["T"] is PdfString name)
        {
            var bytes = name.Bytes;
            for (int n = 2; _rootNames.Contains(Encoding.Latin1.GetString(bytes)); n++) bytes = Suffixed(name.Bytes, n);
            name.Bytes = bytes;
            _rootNames.Add(Encoding.Latin1.GetString(bytes));
        }
        if (!_same && _source.Dict(_source.Catalog, "AcroForm") is { } form)
        {
            foreach (string key in new[] { "DA", "Q" })
            {
                if (!root.ContainsKey(key) && form[key] is { } inherited) root[key] = key == "DA" ? FixDefaultAppearance(inherited) : Copy(inherited);
            }
        }
        fields.Items.Add(reference);
    }

    private HashSet<string> RootNames(PdfArray fields) =>
        [.. fields.Items.Select(f => _target.Resolve(f) as PdfDictionary).Select(d => d?["T"]).OfType<PdfString>().Select(t => Encoding.Latin1.GetString(t.Bytes))];

    // Names are text strings: the suffix is written in the encoding the name has.
    private static byte[] Suffixed(byte[] name, int n)
    {
        string suffix = "_" + n;
        bool utf16 = name.Length >= 2 && name[0] == 0xFE && name[1] == 0xFF;
        return [.. name, .. utf16 ? Encoding.BigEndianUnicode.GetBytes(suffix) : Encoding.ASCII.GetBytes(suffix)];
    }

    private PdfArray TargetFields()
    {
        var form = _target.Dict(_target.Catalog, "AcroForm");
        if (form is null)
        {
            form = new PdfDictionary();
            _target.Catalog["AcroForm"] = form;
        }
        var fields = _target.Array(form, "Fields");
        if (fields is null)
        {
            fields = new PdfArray([]);
            form["Fields"] = fields;
        }
        if (!_formMerged && !_same)
        {
            _formMerged = true;
            MergeDefaults(form);
        }
        return fields;
    }

    // The fields' default resources come along so that a field's /DA finds its font; a name the target has is not replaced.
    private void MergeDefaults(PdfDictionary form)
    {
        if (_source.Dict(_source.Catalog, "AcroForm") is not { } original) return;
        if (_source.Bool(original, "NeedAppearances") == true) form["NeedAppearances"] = new PdfBoolean(true);
        if (_source.Dict(original, "DR") is not { } resources) return;
        var into = _target.Dict(form, "DR");
        if (into is null)
        {
            into = new PdfDictionary();
            form["DR"] = into;
        }
        foreach (var (category, value) in resources.Entries)
        {
            if (_source.Resolve(value) is not PdfDictionary names) continue;
            var group = _target.Dict(into, category);
            if (group is null)
            {
                group = new PdfDictionary();
                into[category] = group;
            }
            foreach (var (name, item) in names.Entries)
            {
                if (!group.ContainsKey(name)) group.Add(name, Copy(item));
                else if (category == "Font" && !SameFont(names[name], group[name]))
                {
                    // The copied fields name this font in their /DA, so it has to come across under a name of its own.
                    string fresh = name;
                    for (int n = 2; group.ContainsKey(fresh); n++) fresh = $"{name}_{n}";
                    group.Add(fresh, Copy(item));
                    _fontRenames[name] = fresh;
                }
            }
        }
    }

    private bool SameFont(PdfObject? source, PdfObject? target) =>
        _source.Resolve(source) is PdfDictionary a && _target.Resolve(target) is PdfDictionary b && a.ToString() == b.ToString();

    private PdfObject FixDefaultAppearance(PdfObject value)
    {
        if (_fontRenames.Count == 0 || PdfText.Read(_source, value) is not { } da) return Copy(value);
        string fixedText = Regex.Replace(da, @"/([^\s/<>\[\]()]+)(\s+[-+\d.]+\s+Tf)",
            m => _fontRenames.TryGetValue(m.Groups[1].Value, out var renamed) ? $"/{renamed}{m.Groups[2].Value}" : m.Value);
        return PdfText.ToObject(fixedText);
    }

    private void Record(int sourceNumber, PdfReference copy)
    {
        if (!_copies.TryGetValue(sourceNumber, out var list)) _copies[sourceNumber] = list = [];
        if (!list.Contains(copy)) list.Add(copy);
    }

    // Calculation order (12.7.6.2): the copies of the fields the source lists follow what the target lists.
    private void CarryOrder()
    {
        if (_source.Dict(_source.Catalog, "AcroForm") is { } form && _source.Array(form, "CO") is { } order
            && _target.Dict(_target.Catalog, "AcroForm") is { } into)
        {
            var added = order.Items.OfType<PdfReference>().SelectMany(r => _copies.GetValueOrDefault(r.Number) ?? []).ToList();
            if (added.Count > 0)
            {
                var list = _target.Array(into, "CO");
                if (list is null) into["CO"] = list = new PdfArray([]);
                list.Items.AddRange(added);
            }
        }
        _copies.Clear();
    }

    // A group that lost some of its buttons keeps the export values of the ones that came, and a value naming a button that stayed behind is Off (the rule of PageCleanup.ForgetButton).
    private void TrimGroups()
    {
        foreach (var (kids, group) in _groups)
        {
            var (source, copy, positions) = group;
            var all = _source.Array(source, "Kids");
            if (all is null || positions.Count == 0 || positions.Count >= all.Items.Count || positions.Contains(-1)) continue;
            if (!InheritedButton(source)) continue;
            if (_source.Array(source, "Opt") is { } options)
            {
                copy["Opt"] = new PdfArray([.. positions.Where(p => p < options.Items.Count).Select(p => Copy(options.Items[p]))]);
            }
            var states = positions.Select(p => _source.Dict(_source.Dict(_source.Resolve(all.Items[p]) as PdfDictionary, "AP"), "N")).OfType<PdfDictionary>().ToList();
            if (copy["V"] is PdfName { Value: not "Off" } value && states.Count > 0 && !states.Any(s => s.ContainsKey(value.Value))) copy["V"] = new PdfName("Off");
        }
        _groups.Clear();
    }

    private bool InheritedButton(PdfDictionary field)
    {
        for (int depth = 0; field is not null && depth < MaxFieldDepth; depth++)
        {
            if (_source.Name(field, "FT") is { } type) return type == "Btn";
            field = _source.Dict(field, "Parent")!;
        }
        return false;
    }
}
