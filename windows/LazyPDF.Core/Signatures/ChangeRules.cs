namespace LazyPDF.Core;

// What each kind of object may change into (ISO 32000-1 12.8.2.2 and 12.7.4.5).
internal sealed partial class ChangeDetector
{
    private void Modified(int n, PdfObject before, PdfObject after)
    {
        // A key written twice reads as the first or the last depending on the parser.
        if (before is PdfDictionary x && after is PdfDictionary y && RepeatChanged(x, y)) Report(SignatureChangeKind.Other, n, allowed: false);
        else if (n == _catalog && before is PdfDictionary catalogA && after is PdfDictionary catalogB) Catalog(catalogA, catalogB);
        else if (n == _acroForm && before is PdfDictionary formA && after is PdfDictionary formB) AcroForm(n, formA, formB);
        else if (n == _fieldsArray && !InContent(n) && before is PdfArray fieldsA && after is PdfArray fieldsB) FieldsDiff(fieldsA.Items, fieldsB.Items);
        else if (_fields.TryGetValue(n, out var node) && before is PdfDictionary fa && after is PdfDictionary fb) Field(n, node, fa, fb);
        else if (_pages.TryGetValue(n, out int pageIndex) && before is PdfDictionary pa && after is PdfDictionary pb) Page(n, pageIndex, pa, pb);
        else if (_annotArrays.TryGetValue(n, out int arrayPage) && !InContent(n) && before is PdfArray aa && after is PdfArray ab) AnnotsDiff(aa.Items, ab.Items, arrayPage);
        else if (_widgetFields.TryGetValue(n, out int owner) && before is PdfDictionary wa && after is PdfDictionary wb) Widget(n, _fields[owner], wa, wb);
        else if (_annots.TryGetValue(n, out int annotPage) && before is PdfDictionary && after is PdfDictionary && !InContent(n) && !Foreign(n)) Report(SignatureChangeKind.Comment, n, annotPage);
        else if (Held(n)) Report(_pages.ContainsKey(n) ? SignatureChangeKind.PageStructure : InContent(n) ? SignatureChangeKind.PageContent : SignatureChangeKind.Other, n, allowed: false);
        else if (before is PdfDictionary treeNode && _a.Name(treeNode, "Type") == "Pages") Report(SignatureChangeKind.PageStructure, n, allowed: false);
        else if (InContent(n)) Report(SignatureChangeKind.PageContent, n, allowed: false);
        else if ((n == _info || n == _metadata) && !Foreign(n)) Report(SignatureChangeKind.Metadata, n);
        else if (AppearanceOwners(n) is { } owners && !Foreign(n)) Appearances(n, owners);
        else if (InDss(n)) Report(SignatureChangeKind.ValidationData, n);
        else if (IsReachable(n)) Report(SignatureChangeKind.Other, n, allowed: false);
    }

    private bool Held(int n) => _annots.ContainsKey(n) || _fields.ContainsKey(n) || _pages.ContainsKey(n) || _widgetFields.ContainsKey(n);

    private void Removed(int n, bool stillReferenced)
    {
        // When the reference that held the object was taken out, that change is reported there; one that still points at it is a dangling page, field or annotation.
        if (Held(n) && !stillReferenced) return;
        if (Held(n)) Report(_pages.ContainsKey(n) ? SignatureChangeKind.PageStructure : SignatureChangeKind.Other, n, allowed: false);
        else if (InContent(n)) Report(SignatureChangeKind.PageContent, n, allowed: false);
        else if (AppearanceOwners(n) is { } owners && !Foreign(n)) Appearances(n, owners);
        else if (IsReachable(n)) Report(SignatureChangeKind.Other, n, allowed: false);
    }

    // New objects are harmless unless an object of the signed revision already pointed at the number: whatever
    // the update says about them, that reference now shows them.
    private void Unclaimed(List<int> added)
    {
        if (added.Count == 0) return;
        var targets = new HashSet<int>(added);
        var seen = new HashSet<int>();
        foreach (int n in _a.ObjectNumbers)
        {
            if (_a.Get(n) is { } value) Collect(value, targets, seen, 0);
        }
        foreach (int n in seen) Report(InContent(n) ? SignatureChangeKind.PageContent : SignatureChangeKind.Other, n, allowed: false);
    }

    private static void Collect(PdfObject value, HashSet<int> targets, HashSet<int> hits, int depth)
    {
        if (depth > MaxDepth) return;
        switch (value)
        {
            case PdfReference r when targets.Contains(r.Number):
                hits.Add(r.Number);
                break;
            case PdfArray array:
                foreach (var item in array.Items) Collect(item, targets, hits, depth + 1);
                break;
            case PdfDictionary dictionary:
                foreach (var (_, item) in dictionary.Entries) Collect(item, targets, hits, depth + 1);
                break;
            case PdfStream stream:
                Collect(stream.Dictionary, targets, hits, depth + 1);
                break;
        }
    }

    private void Catalog(PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            switch (key)
            {
                case "DSS":
                case "Extensions":
                case "Version":
                    Report(SignatureChangeKind.ValidationData, _catalog);
                    break;
                case "AcroForm":
                    CatalogForm(a[key], b[key]);
                    break;
                case "Perms":
                    Report(SignatureChangeKind.Signature, _catalog, allowed: false);
                    break;
                case "Metadata":
                    Report(SignatureChangeKind.Metadata, _catalog);
                    break;
                default:
                    Report(SignatureChangeKind.PageStructure, _catalog, allowed: false);
                    break;
            }
        }
    }

    private void CatalogForm(PdfObject? before, PdfObject? after)
    {
        // The same indirect object is compared when it comes up on its own; another generation reads as nothing.
        if (before is PdfReference r1 && after is PdfReference r2 && r1.Number == r2.Number)
        {
            Report(SignatureChangeKind.Form, _catalog, allowed: false);
            return;
        }
        var a = before is null ? new PdfDictionary() : _a.Resolve(before) as PdfDictionary;
        var b = _b.Resolve(after) as PdfDictionary;
        if (a is null || b is null)
        {
            Report(SignatureChangeKind.Form, _catalog, allowed: false);
            return;
        }
        AcroForm(_catalog, a, b);
    }

    private void AcroForm(int n, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            switch (key)
            {
                case "Fields":
                    var itemsA = (_a.Resolve(a[key]) as PdfArray)?.Items ?? [];
                    var itemsB = (_b.Resolve(b[key]) as PdfArray)?.Items ?? [];
                    if (a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number) Report(SignatureChangeKind.Form, n, allowed: false);
                    else FieldsDiff(itemsA, itemsB);
                    break;
                case "SigFlags":
                    Report(SignatureChangeKind.Signature, n, allowed: true);
                    break;
                case "NeedAppearances":
                case "DR":
                case "DA":
                case "Q":
                    Report(SignatureChangeKind.FormFill, n);
                    break;
                default:
                    Report(SignatureChangeKind.Form, n, allowed: false);
                    break;
            }
        }
    }

    private void FieldsDiff(List<PdfObject> before, List<PdfObject> after)
    {
        var old = before.OfType<PdfReference>().ToHashSet();
        var kept = after.OfType<PdfReference>().ToHashSet();
        foreach (int n in old.Where(r => !kept.Contains(r)).Select(r => r.Number)) Report(SignatureChangeKind.Form, n, field: _fields.TryGetValue(n, out var node) ? node.Name : null, allowed: false);
        foreach (var reference in after.OfType<PdfReference>().Where(r => !old.Contains(r)))
        {
            var field = _b.Get(reference.Number) as PdfDictionary;
            bool signature = IsSignatureField(field);
            Report(signature ? SignatureChangeKind.Signature : SignatureChangeKind.Form, reference.Number, field: FieldName(field), allowed: signature && SignatureAdded(field));
        }
        // Entries that are not references are in the array to see: a direct dictionary is a field of its own.
        if (DirectChanged(before, after) || Reordered(before, after)) Report(SignatureChangeKind.Form, 0, allowed: false);
    }

    private static bool DirectChanged(List<PdfObject> before, List<PdfObject> after) =>
        !before.Where(i => i is not PdfReference).Select(Text).SequenceEqual(after.Where(i => i is not PdfReference).Select(Text));

    // The order of the entries both lists hold, direct ones among them, is the stacking of annotations and the tab order of fields.
    private static bool Reordered(List<PdfObject> before, List<PdfObject> after)
    {
        var old = before.Select(Text).ToHashSet();
        var kept = after.Select(Text).ToHashSet();
        return !before.Select(Text).Where(kept.Contains).SequenceEqual(after.Select(Text).Where(old.Contains));
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

    // A signature is only there when its dictionary is an object of the file with a byte range that closes at a revision;
    // a field that holds anything else is a drawing, whatever its /Type claims. It has to be written by the update, not
    // one the signed revision already held, and to belong to one field.
    private bool IsSignature(PdfObject? value) =>
        value is PdfReference r && _b.Entries.TryGetValue(r.Number, out var entry) && entry.Kind == PdfDocument.EntryKind.InUse
        && entry.Offset >= _a.Length && _signatures.Contains(entry.Offset) && ReferenceCount(r.Number) == 1;

    private int ReferenceCount(int n)
    {
        if (_referenceCounts is null)
        {
            _referenceCounts = [];
            foreach (int number in _b.ObjectNumbers)
            {
                if (_b.Get(number) is { } value) CountReferences(value, _referenceCounts, 0);
            }
        }
        return _referenceCounts.GetValueOrDefault(n);
    }

    private static void CountReferences(PdfObject value, Dictionary<int, int> counts, int depth)
    {
        if (depth > MaxDepth) return;
        switch (value)
        {
            case PdfReference r:
                counts[r.Number] = counts.GetValueOrDefault(r.Number) + 1;
                break;
            case PdfArray array:
                foreach (var item in array.Items) CountReferences(item, counts, depth + 1);
                break;
            case PdfDictionary dictionary:
                foreach (var (_, item) in dictionary.Entries) CountReferences(item, counts, depth + 1);
                break;
            case PdfStream stream:
                CountReferences(stream.Dictionary, counts, depth + 1);
                break;
        }
    }

    private bool IsTimestamp(PdfDictionary? field) => _b.Resolve(ValueOf(field)) is PdfDictionary v && _b.Name(v, "Type") == "DocTimeStamp";

    // A signature field that came with a signature: any signature where the level permits signing, and a document time
    // stamp that shows nothing whatever the level, because anyone can have a real time stamp made.
    private bool SignatureAdded(PdfDictionary? field) =>
        IsSignature(ValueOf(field)) && (Permits(SignatureChangeKind.Signature) || (IsTimestamp(field) && ShowsNothing(field)));

    // Neither the field nor its widgets, kids or parents, have an area to show.
    private bool ShowsNothing(PdfDictionary? field)
    {
        var top = field;
        for (int i = 0; top is not null && i < MaxDepth && _b.Dict(top, "Parent") is { } parent; i++) top = parent;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var pending = new Stack<PdfDictionary>();
        if (top is not null) pending.Push(top);
        while (pending.Count > 0 && seen.Count < MaxFields)
        {
            var node = pending.Pop();
            if (!seen.Add(node)) continue;
            if (_b.Rect(node, "Rect") is not null) return false;
            foreach (var kid in _b.Array(node, "Kids")?.Items ?? []) if (_b.Resolve(kid) is PdfDictionary child) pending.Push(child);
        }
        return true;
    }

    private string? FieldName(PdfDictionary? field) => field is null ? null : PdfText.Read(_b, field["T"]);

    private void Field(int n, FieldNode node, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            if (key == "V" && node.IsSignature)
            {
                Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: !node.HasValue && SignatureAdded(b) && !IsLocked(node.Name));
            }
            else if (key is "AP" or "AS")
            {
                FieldChange(n, node, filling: !node.HasValue || !node.IsSignature);
            }
            else if (key is "V" or "M")
            {
                FieldChange(n, node, filling: true);
            }
            else if (key == "Lock" && !node.HasValue)
            {
                continue;
            }
            else
            {
                Report(SignatureChangeKind.Form, n, field: node.Name, allowed: false);
            }
        }
    }

    private void FieldChange(int n, FieldNode node, bool filling)
    {
        if (node.IsSignature)
        {
            Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: filling && SignatureAdded(_b.Get(node.Number) as PdfDictionary));
            return;
        }
        Report(SignatureChangeKind.FormFill, n, field: node.Name, allowed: filling && Permits(SignatureChangeKind.FormFill) && !IsLocked(node.Name));
    }

    // A widget kept apart from its field: the appearance and state are the field's fill, the rest is layout.
    private void Widget(int n, FieldNode owner, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            if (key is "AP" or "AS")
            {
                FieldChange(n, owner, filling: !owner.HasValue || !owner.IsSignature);
            }
            else
            {
                Report(SignatureChangeKind.Form, n, field: owner.Name, allowed: false);
            }
        }
    }

    private void Page(int n, int index, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            if (key == "Annots")
            {
                if (a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number) Report(SignatureChangeKind.PageStructure, n, index, allowed: false);
                else AnnotsDiff((_a.Resolve(a[key]) as PdfArray)?.Items ?? [], (_b.Resolve(b[key]) as PdfArray)?.Items ?? [], index);
            }
            else if (key is "Contents" or "Resources")
            {
                Report(SignatureChangeKind.PageContent, n, index, allowed: false);
            }
            else
            {
                Report(SignatureChangeKind.PageStructure, n, index, allowed: false);
            }
        }
    }

    private void AnnotsDiff(List<PdfObject> before, List<PdfObject> after, int page)
    {
        var old = before.OfType<PdfReference>().ToHashSet();
        var kept = after.OfType<PdfReference>().ToHashSet();
        foreach (int n in old.Where(r => !kept.Contains(r)).Select(r => r.Number))
        {
            var removed = _a.Get(n) as PdfDictionary;
            if (removed is not null && _a.Name(removed, "Subtype") == "Widget") Report(SignatureChangeKind.Form, n, page, allowed: false);
            else Report(SignatureChangeKind.Comment, n, page);
        }
        foreach (var reference in after.OfType<PdfReference>().Where(r => !old.Contains(r)))
        {
            var added = _b.Get(reference.Number) as PdfDictionary;
            if (added is not null && _b.Name(added, "Subtype") == "Widget")
            {
                bool signature = IsSignatureField(added);
                Report(signature ? SignatureChangeKind.Signature : SignatureChangeKind.Form, reference.Number, page, allowed: signature && SignatureAdded(added));
            }
            else
            {
                Report(SignatureChangeKind.Comment, reference.Number, page);
            }
        }
        if (DirectChanged(before, after) || Reordered(before, after)) Report(SignatureChangeKind.Comment, 0, page);
    }

    // A stream or dictionary that an annotation or field's appearance uses follows that owner's rule; one shared by several follows each.
    private void Appearances(int n, List<int> owners)
    {
        foreach (int owner in owners)
        {
            if (_fields.TryGetValue(owner, out var node) || (_widgetFields.TryGetValue(owner, out int fieldNumber) && _fields.TryGetValue(fieldNumber, out node))) FieldChange(n, node!, filling: !node!.HasValue || !node.IsSignature);
            else Report(SignatureChangeKind.Comment, n, _annots.GetValueOrDefault(owner, -1));
        }
    }

    private List<int>? AppearanceOwners(int n)
    {
        if (_appearanceOwners is null)
        {
            _appearanceOwners = [];
            var owners = _annots.Keys.Concat(_fields.Keys).Concat(_widgetFields.Keys).ToList();
            foreach (int owner in owners)
            {
                if (_a.Get(owner) is not PdfDictionary dictionary || _a.Dict(dictionary, "AP") is not { } ap) continue;
                var seen = new HashSet<int>();
                Reach(_a, ap, seen, 4096);
                foreach (int reached in seen)
                {
                    if (!_appearanceOwners.TryGetValue(reached, out var list)) _appearanceOwners[reached] = list = [];
                    list.Add(owner);
                }
            }
        }
        return _appearanceOwners.GetValueOrDefault(n);
    }

    private bool InContent(int n)
    {
        if (_content is null)
        {
            _content = [];
            foreach (var page in _a.Pages)
            {
                foreach (var (key, value) in page.Dictionary.Entries)
                {
                    if (key is "Annots" or "Parent") continue;
                    Reach(_a, value, _content, 1_000_000);
                }
                var node = _a.Dict(page.Dictionary, "Parent");
                for (int depth = 0; node is not null && depth < MaxDepth; depth++)
                {
                    Reach(_a, node["Resources"], _content, 1_000_000);
                    node = _a.Dict(node, "Parent");
                }
            }
            foreach (var pageNumber in _pages.Keys) _content.Remove(pageNumber);
        }
        return _content.Contains(n);
    }

    // What the rest of the document uses, apart from the places the lax roles (annotations, appearances, information,
    // validation data) are reached by. An object found here has a job that no level makes room for.
    private bool Foreign(int n)
    {
        if (_foreign is null)
        {
            _foreign = [];
            var pending = new Stack<(PdfObject Value, int? Owner)>();
            pending.Push((_a.Trailer, 0));
            while (pending.Count > 0 && _foreign.Count < 5_000_000)
            {
                var (value, owner) = pending.Pop();
                switch (value)
                {
                    case PdfReference r:
                        if (_foreign.Add(r.Number) && _a.Get(r.Number) is { } target) pending.Push((target, r.Number));
                        break;
                    case PdfArray array:
                        foreach (var item in array.Items) pending.Push((item, null));
                        break;
                    case PdfDictionary dictionary:
                        foreach (var (key, item) in dictionary.Entries)
                        {
                            if (!RoleKey(owner, key)) pending.Push((item, null));
                        }
                        break;
                    case PdfStream stream:
                        pending.Push((stream.Dictionary, owner));
                        break;
                }
            }
        }
        return _foreign.Contains(n);
    }

    // Owner 0 is the trailer.
    private bool RoleKey(int? owner, string key) => owner switch
    {
        0 => key == "Info",
        { } number when number == _catalog => key is "DSS" or "AcroForm" or "Metadata" or "StructTreeRoot",
        { } number when _pages.ContainsKey(number) => key == "Annots",
        _ => false,
    };

    private bool IsReachable(int n)
    {
        if (_reachable is null)
        {
            _reachable = [];
            Reach(_a, _a.Trailer, _reachable, 5_000_000);
        }
        return _reachable.Contains(n);
    }

    // Validation data is what the catalog's /DSS holds and nothing else does: an object the document uses another way keeps that role.
    private bool InDss(int n)
    {
        if (_dss is null)
        {
            _dss = [];
            if (_a.Dict(_a.Catalog, "DSS") is { } dss && dss.Entries.All(e => e.Key is "Type" or "VRI" or "Certs" or "OCSPs" or "CRLs"))
            {
                AddReference<PdfDictionary>(_a.Catalog["DSS"], _dss);
                foreach (string key in (string[])["Certs", "OCSPs", "CRLs"]) AddStreams(dss[key], _dss);
                if (_a.Dict(dss, "VRI") is { } vri && vri.Entries.All(e => IsDigestName(e.Key)))
                {
                    AddReference<PdfDictionary>(dss["VRI"], _dss);
                    foreach (var (_, entry) in vri.Entries)
                    {
                        AddReference<PdfDictionary>(entry, _dss);
                        if (_a.Resolve(entry) is not PdfDictionary set) continue;
                        foreach (string key in (string[])["Cert", "OCSP", "CRL"]) AddStreams(set[key], _dss);
                    }
                }
            }
        }
        return _dss.Contains(n) && !Foreign(n);
    }

    // The 40 hex digits of the SHA-1 that name a signature's entry in /VRI (ETSI EN 319 142-1 5.4.2).
    private static bool IsDigestName(string key) => key.Length == 40 && key.All(char.IsAsciiHexDigit);

    private void AddReference<T>(PdfObject? value, HashSet<int> numbers) where T : PdfObject
    {
        if (value is PdfReference r && _a.Get(r.Number) is T) numbers.Add(r.Number);
    }

    // An array of validation data and the streams in it, which are the objects an update to the data may touch.
    private void AddStreams(PdfObject? value, HashSet<int> numbers)
    {
        AddReference<PdfArray>(value, numbers);
        if (_a.Resolve(value) is not PdfArray array) return;
        foreach (var item in array.Items)
        {
            if (item is PdfReference r && _a.Get(r.Number) is PdfStream) numbers.Add(r.Number);
        }
    }

    // The objects a value reaches in a document, through references, to a bounded count and depth.
    private static void Reach(PdfDocument document, PdfObject? start, HashSet<int> seen, int limit)
    {
        var pending = new Stack<PdfObject>();
        if (start is not null) pending.Push(start);
        while (pending.Count > 0 && seen.Count < limit)
        {
            switch (pending.Pop())
            {
                case PdfReference r:
                    if (seen.Add(r.Number) && document.Get(r.Number) is { } target) pending.Push(target);
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) pending.Push(item);
                    break;
                case PdfDictionary dictionary:
                    foreach (var (_, item) in dictionary.Entries) pending.Push(item);
                    break;
                case PdfStream stream:
                    pending.Push(stream.Dictionary);
                    break;
            }
        }
    }

    // Compared with every entry of a repeated key, which ToString leaves out but another parser may read.
    private static bool Equal(PdfDictionary a, PdfDictionary b, string key) => Values(a, key) == Values(b, key);

    private static string Values(PdfDictionary dictionary, string key) =>
        string.Join(' ', dictionary.Entries.Where(e => e.Key == key).Select(e => Text(e.Value)));

    private static bool RepeatChanged(PdfDictionary a, PdfDictionary b) =>
        Keys(a, b).Any(key => !Equal(a, b, key) && (a.Entries.Count(e => e.Key == key) > 1 || b.Entries.Count(e => e.Key == key) > 1));

    private static string Text(PdfObject? value)
    {
        var text = new System.Text.StringBuilder();
        Write(value, text);
        return text.ToString();
    }

    private static void Write(PdfObject? value, System.Text.StringBuilder text)
    {
        switch (value)
        {
            case PdfDictionary dictionary:
                text.Append("<<");
                foreach (var (key, item) in dictionary.Entries)
                {
                    text.Append(new PdfName(key)).Append(' ');
                    Write(item, text);
                    text.Append(' ');
                }
                text.Append(">>");
                break;
            case PdfArray array:
                text.Append('[');
                foreach (var item in array.Items)
                {
                    Write(item, text);
                    text.Append(' ');
                }
                text.Append(']');
                break;
            default:
                text.Append(value);
                break;
        }
    }

    private static IEnumerable<string> Keys(PdfDictionary a, PdfDictionary b) =>
        a.Entries.Select(e => e.Key).Concat(b.Entries.Select(e => e.Key)).Distinct();
}
