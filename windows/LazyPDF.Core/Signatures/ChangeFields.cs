using System.Text.RegularExpressions;

namespace LazyPDF.Core;

// Fields: what filling one changes, which fields an earlier signature locked, and when a new signature field is real.
internal sealed partial class ChangeDetector
{
    private const int MaxDepth = 32;

    private Dictionary<int, HashSet<string>?>? _lockNames;
    private HashSet<string>? _daNames;
    private bool? _readOnly;

    private void Field(int n, FieldNode? node, PdfDictionary a, PdfDictionary b)
    {
        if (node is null)
        {
            Report(SignatureChangeKind.Form, n, allowed: false);
            return;
        }
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            if (key == "V" && node.IsSignature) Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: !node.HasValue && SignatureAdded(b) && !IsLocked(node));
            else if (key is "Type" or "Subtype" or "Rect" or "F" or "P" && node.IsSignature && !node.HasValue) Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: Placed(a, b, key) && SignatureAdded(b) && !IsLocked(node));
            else if (key is "AP" or "AS") FieldChange(n, node, filling: !node.HasValue || !node.IsSignature);
            else if (key is "V" or "M" or "I") FieldChange(n, node, filling: true);
            else if (key is "DA" or "TI" or "RV" && !node.IsSignature) FieldChange(n, node, filling: true);
            else if (key != "Lock" || !node.IsSignature || node.HasValue) Report(SignatureChangeKind.Form, n, field: node.Name, allowed: false);
        }
    }

    // The appearance or value object of a field, or of a comment.
    private void Part(int n, Job job, bool added)
    {
        if (job.Kind == JobKind.Appearance && job.Owner == 0)
        {
            Report(SignatureChangeKind.Comment, n, job.Page);
        }
        else if (_jobsA.Fields.GetValueOrDefault(job.Owner) is { } node)
        {
            FieldChange(n, node, filling: !node.HasValue || !node.IsSignature);
        }
        else if (added && _jobsB.Fields.GetValueOrDefault(job.Owner) is { } fresh && !IsListed(_a.Entries.GetValueOrDefault(job.Owner)))
        {
            Report(SignatureChangeKind.Signature, n, job.Page, fresh.Name, allowed: fresh.IsSignature && SignatureAdded(_b.Get(job.Owner) as PdfDictionary));
        }
        else
        {
            Report(SignatureChangeKind.Form, n, job.Page, allowed: false);
        }
    }

    private void AddedField(int n, int page)
    {
        var field = _b.Get(n) as PdfDictionary;
        bool signature = IsSignatureField(field);
        Report(signature ? SignatureChangeKind.Signature : SignatureChangeKind.Form, n, page, FieldName(field), allowed: signature && SignatureAdded(field));
    }

    private void FieldChange(int n, FieldNode node, bool filling)
    {
        if (node.IsSignature)
        {
            Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: filling && SignatureAdded(_b.Get(node.Number) as PdfDictionary));
            return;
        }
        Report(SignatureChangeKind.FormFill, n, field: node.Name, allowed: filling && Permits(SignatureChangeKind.FormFill) && !IsLocked(node) && !ReadOnly(node) && !Pushbutton(node));
    }

    // Signing a field that has no widget gives it one: the keys of an annotation (12.5.2, 12.7.4.5). A field that was
    // a widget when it was signed is on the page, and where it sits is part of what was signed.
    private static bool Placed(PdfDictionary a, PdfDictionary b, string key) => key switch
    {
        "Type" => a["Type"] is null && b["Type"] is PdfName { Value: "Annot" },
        "Subtype" => a["Subtype"] is null && b["Subtype"] is PdfName { Value: "Widget" },
        _ => a["Subtype"] is null,
    };

    // The nearest dictionary of the field or its /Parent chain that has the key (12.7.3.1), as the signed revision has it.
    private PdfDictionary? Holder(FieldNode node, string key)
    {
        var field = _a.Get(node.Number) as PdfDictionary;
        for (int i = 0; field is not null && i < MaxDepth; i++)
        {
            if (field.ContainsKey(key)) return field;
            field = _a.Dict(field, "Parent");
        }
        return null;
    }

    // A field no honest fill changes (bit 1 of /Ff).
    private bool ReadOnly(FieldNode node) =>
        Holder(node, "Ff") is { } holder && (_a.Number(holder, "Ff") is not { } flags || ((long)flags & 1) != 0);

    // A pushbutton has no value to fill (12.7.4.2.2, bit 17 of /Ff): what it draws is fixed.
    private bool Pushbutton(FieldNode node) =>
        Holder(node, "FT") is { } type && _a.Name(type, "FT") == "Btn" && Holder(node, "Ff") is { } holder && _a.Number(holder, "Ff") is { } flags && ((long)flags & 1 << 16) != 0;

    // A lock or a read-only field holds how a field is drawn as well as what it says, and a viewer that rebuilds
    // appearances (12.7.2) draws it from the form's defaults.
    private bool Guarded => _locks.Count > 0 || (_readOnly ??= _jobsA.Fields.Values.Any(ReadOnly));

    // Defaults change only for a form nothing guards, or by gaining a font no signed field names in its /DA: that cannot change how one draws.
    private bool DefaultsAllowed(bool grew) => Permits(SignatureChangeKind.FormFill) && (!Guarded || grew);

    private bool Grew(PdfDictionary a, PdfDictionary b, int depth)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            bool grown = depth switch
            {
                0 => key == "Font" && Grown(a[key], b[key], 1),
                1 => !a.ContainsKey(key) && !DaNames().Contains(key),
                _ => false,
            };
            if (!grown) return false;
        }
        return true;
    }

    private bool Grown(PdfObject? before, PdfObject? after, int depth) =>
        (before is null ? new PdfDictionary() : _a.Resolve(before) as PdfDictionary) is { } a && _b.Resolve(after) as PdfDictionary is { } b && Grew(a, b, depth);

    // The font names the default appearance strings of the signed revision use, fields and form alike.
    private HashSet<string> DaNames() => _daNames ??= _a.ObjectNumbers.Select(_a.Get).OfType<PdfObject>().SelectMany(Dictionaries)
        .Select(d => PdfText.Read(_a, d["DA"])).OfType<string>().SelectMany(da => Regex.Matches(da, @"/[^\s/<>\[\]()]+").Select(m => Unescaped(m.Value[1..]))).ToHashSet();

    private static string Unescaped(string name) =>
        Regex.Replace(name, "#[0-9A-Fa-f]{2}", m => ((char)Convert.ToInt32(m.Value[1..], 16)).ToString());

    private static IEnumerable<PdfDictionary> Dictionaries(PdfObject value)
    {
        var pending = new Stack<PdfObject>();
        pending.Push(value);
        while (pending.Count > 0)
        {
            switch (pending.Pop())
            {
                case PdfArray array:
                    foreach (var item in array.Items) pending.Push(item);
                    break;
                case PdfDictionary dictionary:
                    yield return dictionary;
                    foreach (var (_, item) in dictionary.Entries) pending.Push(item);
                    break;
                case PdfStream stream:
                    pending.Push(stream.Dictionary);
                    break;
            }
        }
    }

    private bool IsSignatureField(PdfDictionary? field)
    {
        for (int i = 0; field is not null && i < MaxDepth; i++)
        {
            if (_b.Name(field, "FT") is { } type) return type == "Sig";
            field = _b.Dict(field, "Parent");
        }
        return false;
    }

    // The value of a field, which a kid widget may leave to its parent.
    private PdfObject? ValueOf(PdfDictionary? field)
    {
        for (int i = 0; field is not null && i < MaxDepth; i++)
        {
            if (field["V"] is { } value) return value;
            field = _b.Dict(field, "Parent");
        }
        return null;
    }

    private string? FieldName(PdfDictionary? field) => field is null ? null : PdfText.Read(_b, field["T"]);

    // A signature is only there when its dictionary is an object of the file with a byte range that closes at a revision;
    // a field that holds anything else is a drawing, whatever its /Type claims. It has to be written by the update, not
    // one the signed revision already held, and to belong to one field.
    private bool IsSignature(PdfObject? value) =>
        value is PdfReference r && _b.Entries.TryGetValue(r.Number, out var entry) && entry.Kind == PdfDocument.EntryKind.InUse
        && entry.Offset >= _a.Length && _signatures.Contains(entry.Offset) && References().GetValueOrDefault(r.Number) == 1;

    private bool IsTimestamp(PdfDictionary? field) => _b.Resolve(ValueOf(field)) is PdfDictionary v && _b.Name(v, "Type") == "DocTimeStamp";

    // A signature field that came with a signature and no action: any signature where the level permits signing, and
    // a document time stamp that shows nothing whatever the level, because anyone can have a real time stamp made.
    private bool SignatureAdded(PdfDictionary? field) =>
        IsSignature(ValueOf(field)) && Quiet(field, area: false) && (Permits(SignatureChangeKind.Signature) || IsTimestamp(field) && Quiet(field, area: true));

    // Neither the field nor its widgets, kids or parents, run an action, and with area set have no area to show. The
    // dictionary itself and every parent over it count whether or not a /Kids array lists them.
    private bool Quiet(PdfDictionary? field, bool area)
    {
        var pending = new Stack<PdfDictionary>();
        for (int i = 0; field is not null && i < MaxDepth; i++)
        {
            pending.Push(field);
            field = _b.Dict(field, "Parent");
        }
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        while (pending.Count > 0)
        {
            var node = pending.Pop();
            if (!seen.Add(node)) continue;
            if (seen.Count > 200_000 || area && HasArea(node) || node.ContainsKey("A") || node.ContainsKey("AA")) return false;
            foreach (var kid in _b.Array(node, "Kids")?.Items ?? []) if (_b.Resolve(kid) is PdfDictionary child) pending.Push(child);
        }
        return true;
    }

    // Anything but one /Rect of four numbers that make an empty box counts as an area: a reader may take a value that is no number as 0 or read the other /Rect.
    private static bool HasArea(PdfDictionary node)
    {
        int written = node.Entries.Count(e => e.Key == "Rect");
        if (written == 0) return false;
        if (written > 1 || node["Rect"] is not PdfArray { Items.Count: 4 } rect || rect.Items.Any(i => i is not PdfNumber)) return true;
        double[] n = [.. rect.Items.Select(i => ((PdfNumber)i).Value)];
        return !new PdfRect(n[0], n[1], n[2], n[3]).IsEmpty;
    }

    // The locks the signed signatures declare (12.7.4.5).
    private void ReadLocks()
    {
        foreach (var (number, node) in _jobsA.Fields)
        {
            if (!node.IsSignature || !node.HasValue || _a.Get(number) is not PdfDictionary field) continue;
            if (_a.Dict(field, "V") is not { } signature || _a.Array(signature, "Reference") is not { } references) continue;
            foreach (var item in references.Items)
            {
                if (_a.Resolve(item) is not PdfDictionary reference || _a.Name(reference, "TransformMethod") != "FieldMDP") continue;
                if (_a.Dict(reference, "TransformParams") is not { } parameters) continue;
                var action = _a.Name(parameters, "Action") switch { "Include" => FieldLockAction.Include, "Exclude" => FieldLockAction.Exclude, _ => FieldLockAction.All };
                var names = _a.Array(parameters, "Fields")?.Items.Select(i => PdfText.Read(_a, i)).OfType<string>().ToHashSet() ?? [];
                _locks.Add((action, names));
            }
        }
    }

    // A name that has fields under it covers them too (12.8.2.4).
    private static bool Covered(HashSet<string> list, string name) =>
        list.Any(n => name == n || name.StartsWith(n + ".", StringComparison.Ordinal));

    private bool IsLocked(FieldNode node)
    {
        if (_locks.Count == 0) return false;
        _lockNames ??= LockNames();
        if (_lockNames.GetValueOrDefault(node.Number) is not { } names) return true;
        return _locks.Any(l => l.Action switch
        {
            FieldLockAction.All => true,
            FieldLockAction.Include => names.Any(n => Covered(l.Names, n)),
            _ => names.Any(n => !Covered(l.Names, n)),
        });
    }

    // Every name a field goes by: the one the /Kids that lead to it spell, the one a reader qualifies it with up its
    // /Parent chain, and those of the fields below it, whose values it hands on (12.7.3.1). A chain that does not end
    // has no names that can be trusted.
    private Dictionary<int, HashSet<string>?> LockNames()
    {
        var names = _jobsA.Fields.ToDictionary(f => f.Key, f => (HashSet<string>?)[f.Value.Name]);
        foreach (var (number, node) in _jobsA.Fields)
        {
            if (Qualified(_a.Get(number) as PdfDictionary) is not { } qualified)
            {
                names[number] = null;
                continue;
            }
            foreach (int up in Ancestors(node).Append(number)) names.GetValueOrDefault(up)?.UnionWith([node.Name, qualified]);
        }
        return names;
    }

    private string? Qualified(PdfDictionary? field)
    {
        var parts = new List<string>();
        for (int i = 0; field is not null; i++, field = _a.Dict(field, "Parent"))
        {
            if (i > MaxDepth) return null;
            if (PdfText.Read(_a, field["T"]) is { } part) parts.Add(part);
        }
        parts.Reverse();
        return string.Join('.', parts);
    }

    private IEnumerable<int> Ancestors(FieldNode node)
    {
        int up = node.Parent;
        for (int i = 0; up != 0 && i < MaxDepth; i++, up = _jobsA.Fields.GetValueOrDefault(up)?.Parent ?? 0) yield return up;
        var field = _a.Get(node.Number) as PdfDictionary;
        for (int i = 0; i < MaxDepth && field?["Parent"] is PdfReference parent; i++, field = _a.Get(parent.Number) as PdfDictionary) yield return parent.Number;
    }
}
