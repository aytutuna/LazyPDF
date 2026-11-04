namespace LazyPDF.Core;

// What each kind of object may change into (ISO 32000-1 12.8.2.2 and 12.7.4.5).
internal sealed partial class ChangeDetector
{
    private void Modified(int n, PdfObject before, PdfObject after)
    {
        if (n == _catalog && before is PdfDictionary catalogA && after is PdfDictionary catalogB) Catalog(catalogA, catalogB);
        else if (n == _acroForm && before is PdfDictionary formA && after is PdfDictionary formB) AcroForm(n, formA, formB);
        else if (n == _fieldsArray && before is PdfArray fieldsA && after is PdfArray fieldsB) FieldsDiff(fieldsA.Items, fieldsB.Items);
        else if (_fields.TryGetValue(n, out var node) && before is PdfDictionary fa && after is PdfDictionary fb) Field(n, node, fa, fb);
        else if (_pages.TryGetValue(n, out int pageIndex) && before is PdfDictionary pa && after is PdfDictionary pb) Page(n, pageIndex, pa, pb);
        else if (_annotArrays.TryGetValue(n, out int arrayPage) && before is PdfArray aa && after is PdfArray ab) AnnotsDiff(aa.Items, ab.Items, arrayPage);
        else if (_widgetFields.TryGetValue(n, out int owner) && before is PdfDictionary wa && after is PdfDictionary wb) Widget(n, _fields[owner], wa, wb);
        else if (_annots.TryGetValue(n, out int annotPage)) Report(SignatureChangeKind.Comment, n, annotPage);
        else if (before is PdfDictionary treeNode && _a.Name(treeNode, "Type") == "Pages") Report(SignatureChangeKind.PageStructure, n, allowed: false);
        else if (n == _info || n == _metadata) Report(SignatureChangeKind.Metadata, n);
        else if (InDss(n) && !InContent(n)) Report(SignatureChangeKind.ValidationData, n);
        else if (AppearanceOwner(n) is { } appearanceOwner) Appearance(n, appearanceOwner);
        else if (InContent(n)) Report(SignatureChangeKind.PageContent, n, allowed: false);
        else if (IsReachable(n)) Report(SignatureChangeKind.Other, n, allowed: false);
    }

    private bool Held(int n) => _annots.ContainsKey(n) || _fields.ContainsKey(n) || _pages.ContainsKey(n) || _widgetFields.ContainsKey(n);

    private void Removed(int n, bool stillReferenced)
    {
        // When the reference that held the object was taken out, that change is reported there; one that still points at it is a dangling page, field or annotation.
        if (Held(n) && !stillReferenced) return;
        if (Held(n)) Report(_pages.ContainsKey(n) ? SignatureChangeKind.PageStructure : SignatureChangeKind.Other, n, allowed: false);
        else if (InContent(n)) Report(SignatureChangeKind.PageContent, n, allowed: false);
        else if (AppearanceOwner(n) is { } owner) Appearance(n, owner);
        else if (IsReachable(n)) Report(SignatureChangeKind.Other, n, allowed: false);
    }

    // New objects that no allowed change took in are harmless unless an object of the signed revision already pointed at the number.
    private void Unclaimed(List<int> added)
    {
        var open = added.Where(n => !_claimed.Contains(n)).ToList();
        if (open.Count == 0) return;
        var targets = new HashSet<int>(open);
        var seen = new HashSet<int>();
        foreach (int n in _a.ObjectNumbers)
        {
            if (_modified.Contains(n) || _a.Get(n) is not { } value) continue;
            Collect(value, targets, seen, 0);
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

    // A new object taken in by a change: it and the new objects it points to belong to that change.
    private void Claim(PdfObject? value, int depth = 0)
    {
        if (depth > MaxDepth) return;
        switch (value)
        {
            case PdfReference r:
                if (_a.Entries.TryGetValue(r.Number, out var e) && e.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed) return;
                if (_claimed.Add(r.Number)) Claim(_b.Get(r.Number), depth + 1);
                break;
            case PdfArray array:
                foreach (var item in array.Items) Claim(item, depth + 1);
                break;
            case PdfDictionary dictionary:
                foreach (var (_, item) in dictionary.Entries) Claim(item, depth + 1);
                break;
            case PdfStream stream:
                Claim(stream.Dictionary, depth + 1);
                break;
        }
    }

    // An "n g obj" after the signed revision that no cross-reference section lists, for a number the signed
    // revision uses: a viewer that scans the file instead of trusting the table (or a repair) would take it for the object.
    private void Orphans()
    {
        var source = _b.Source.Span;
        int from = _a.Length;
        var listed = new HashSet<(int, long)>();
        foreach (var document in _between!.Append(_b))
        {
            foreach (var (n, entry) in document.Entries)
            {
                if (entry.Kind == PdfDocument.EntryKind.InUse) listed.Add((n, entry.Offset));
            }
        }
        var streams = new List<(long Start, long End)>();
        foreach (var (n, entry) in _b.Entries)
        {
            if (entry.Kind == PdfDocument.EntryKind.InUse && entry.Offset >= from && _b.Get(n) is PdfStream stream)
            {
                streams.Add((stream.DataOffset, stream.DataOffset + (_b.Integer(stream.Dictionary, "Length") ?? 0)));
            }
        }

        int pos = from;
        while (pos < source.Length)
        {
            int at = source[pos..].IndexOf("obj"u8);
            if (at < 0) break;
            int obj = pos + at;
            pos = obj + 3;
            if (obj == 0 || source[obj - 1] == (byte)'d' || !TryHeader(source, obj, from, out int number, out int start)) continue;
            if (listed.Contains((number, start)) || streams.Any(r => start >= r.Start && start < r.End)) continue;
            if (_a.Entries.TryGetValue(number, out var existing) && existing.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed)
            {
                Report(InContent(number) ? SignatureChangeKind.PageContent : SignatureChangeKind.Other, number, allowed: false);
            }
        }
    }

    // "n g " just before "obj", starting a line.
    private static bool TryHeader(ReadOnlySpan<byte> source, int obj, int floor, out int number, out int start)
    {
        number = 0;
        start = 0;
        int i = obj;
        if (i == 0 || !PdfLexer.IsWhiteSpace(source[i - 1])) return false;
        while (i > floor && PdfLexer.IsWhiteSpace(source[i - 1])) i--;
        int digitsEnd = i;
        while (i > floor && source[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
        if (i == digitsEnd || !PdfLexer.IsWhiteSpace(source[i - 1])) return false;
        while (i > floor && PdfLexer.IsWhiteSpace(source[i - 1])) i--;
        int numberEnd = i;
        while (i > floor && source[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
        if (i == numberEnd || numberEnd - i > 9 || (i > floor && source[i - 1] is not (10 or 13))) return false;
        start = i;
        return int.TryParse(source[i..numberEnd], out number);
    }

    private void Catalog(PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a[key], b[key])) continue;
            switch (key)
            {
                case "DSS":
                case "Extensions":
                case "Version":
                    Claim(b[key]);
                    Report(SignatureChangeKind.ValidationData, _catalog);
                    break;
                case "AcroForm":
                    CatalogForm(a[key], b[key]);
                    break;
                case "Perms":
                    Report(SignatureChangeKind.Signature, _catalog, allowed: false);
                    break;
                case "Metadata":
                    Claim(b[key]);
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
        // The same indirect object is compared when it comes up on its own.
        if (before is PdfReference r1 && after is PdfReference r2 && r1.Number == r2.Number) return;
        var a = before is null ? new PdfDictionary() : _a.Resolve(before) as PdfDictionary;
        var b = _b.Resolve(after) as PdfDictionary;
        if (a is null || b is null)
        {
            Report(SignatureChangeKind.Form, _catalog, allowed: false);
            return;
        }
        Claim(after);
        AcroForm(_catalog, a, b);
    }

    private void AcroForm(int n, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a[key], b[key])) continue;
            switch (key)
            {
                case "Fields":
                    var itemsA = (_a.Resolve(a[key]) as PdfArray)?.Items ?? [];
                    var itemsB = (_b.Resolve(b[key]) as PdfArray)?.Items ?? [];
                    if (!(a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number)) FieldsDiff(itemsA, itemsB);
                    break;
                case "SigFlags":
                    Report(SignatureChangeKind.Signature, n, allowed: true);
                    break;
                case "NeedAppearances":
                case "DR":
                case "DA":
                case "Q":
                    Claim(b[key]);
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
        var old = before.OfType<PdfReference>().Select(r => r.Number).ToHashSet();
        var kept = after.OfType<PdfReference>().Select(r => r.Number).ToHashSet();
        foreach (int n in old.Where(n => !kept.Contains(n))) Report(SignatureChangeKind.Form, n, field: _fields.TryGetValue(n, out var node) ? node.Name : null, allowed: false);
        foreach (var reference in after.OfType<PdfReference>().Where(r => !old.Contains(r.Number)))
        {
            Claim(reference);
            bool signature = IsSignatureField(_b.Get(reference.Number) as PdfDictionary);
            Report(signature ? SignatureChangeKind.Signature : SignatureChangeKind.Form, reference.Number, field: FieldName(_b.Get(reference.Number) as PdfDictionary),
                   allowed: signature && (IsTimestamp(_b.Get(reference.Number) as PdfDictionary) || Permits(SignatureChangeKind.Signature)));
        }
        // Entries that are not references are in the array to see: a direct dictionary is a new field.
        if (after.Count(i => i is not PdfReference) > before.Count(i => i is not PdfReference)) Report(SignatureChangeKind.Form, 0, allowed: false);
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

    private bool IsTimestamp(PdfDictionary? field) => _b.Dict(field, "V") is { } v && _b.Name(v, "Type") == "DocTimeStamp";

    private string? FieldName(PdfDictionary? field) => field is null ? null : PdfText.Read(_b, field["T"]);

    private void Field(int n, FieldNode node, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a[key], b[key])) continue;
            if (key == "V" && node.IsSignature)
            {
                bool filling = !node.HasValue && b[key] is not null;
                Claim(b[key]);
                Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: filling && (IsTimestamp(b) || Permits(SignatureChangeKind.Signature)));
            }
            else if (key is "AP" or "AS")
            {
                Claim(b[key]);
                FieldChange(n, node, filling: !node.HasValue || !node.IsSignature);
            }
            else if (key is "V" or "M")
            {
                Claim(b[key]);
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
            Report(SignatureChangeKind.Signature, n, field: node.Name, allowed: filling && Permits(SignatureChangeKind.Signature));
            return;
        }
        Report(SignatureChangeKind.FormFill, n, field: node.Name, allowed: filling && Permits(SignatureChangeKind.FormFill) && !IsLocked(node.Name));
    }

    // A widget kept apart from its field: the appearance and state are the field's fill, the rest is layout.
    private void Widget(int n, FieldNode owner, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a[key], b[key])) continue;
            if (key is "AP" or "AS")
            {
                Claim(b[key]);
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
            if (Equal(a[key], b[key])) continue;
            if (key == "Annots")
            {
                if (a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number) continue;
                AnnotsDiff((_a.Resolve(a[key]) as PdfArray)?.Items ?? [], (_b.Resolve(b[key]) as PdfArray)?.Items ?? [], index);
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
        var old = before.OfType<PdfReference>().Select(r => r.Number).ToHashSet();
        var kept = after.OfType<PdfReference>().Select(r => r.Number).ToHashSet();
        foreach (int n in old.Where(n => !kept.Contains(n)))
        {
            var removed = _a.Get(n) as PdfDictionary;
            if (removed is not null && _a.Name(removed, "Subtype") == "Widget") Report(SignatureChangeKind.Form, n, page, allowed: false);
            else Report(SignatureChangeKind.Comment, n, page);
        }
        foreach (var reference in after.OfType<PdfReference>().Where(r => !old.Contains(r.Number)))
        {
            Claim(reference);
            var added = _b.Get(reference.Number) as PdfDictionary;
            if (added is not null && _b.Name(added, "Subtype") == "Widget")
            {
                bool signature = IsSignatureField(added);
                Report(signature ? SignatureChangeKind.Signature : SignatureChangeKind.Form, reference.Number, page,
                       allowed: signature && (IsTimestamp(added) || Permits(SignatureChangeKind.Signature)));
            }
            else
            {
                Report(SignatureChangeKind.Comment, reference.Number, page);
            }
        }
        if (after.Count(i => i is not PdfReference) != before.Count(i => i is not PdfReference)) Report(SignatureChangeKind.Comment, 0, page);
    }

    // A stream or dictionary that only an annotation or field's appearance uses follows that owner's rule.
    private void Appearance(int n, int owner)
    {
        if (_fields.TryGetValue(owner, out var node) || (_widgetFields.TryGetValue(owner, out int fieldNumber) && _fields.TryGetValue(fieldNumber, out node))) FieldChange(n, node!, filling: true);
        else Report(SignatureChangeKind.Comment, n, _annots.GetValueOrDefault(owner, -1));
    }

    private int? AppearanceOwner(int n)
    {
        if (_appearanceOwner is null)
        {
            _appearanceOwner = [];
            var owners = _annots.Keys.Concat(_fields.Keys).Concat(_widgetFields.Keys).ToList();
            foreach (int owner in owners)
            {
                if (_a.Get(owner) is not PdfDictionary dictionary || _a.Dict(dictionary, "AP") is not { } ap) continue;
                var seen = new HashSet<int>();
                Reach(_a, ap, seen, 4096);
                foreach (int reached in seen) _appearanceOwner.TryAdd(reached, owner);
            }
        }
        return _appearanceOwner.TryGetValue(n, out int found) ? found : null;
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
            }
            foreach (var pageNumber in _pages.Keys) _content.Remove(pageNumber);
        }
        return _content.Contains(n);
    }

    private bool IsReachable(int n)
    {
        if (_reachable is null)
        {
            _reachable = [];
            Reach(_a, _a.Trailer, _reachable, 5_000_000);
        }
        return _reachable.Contains(n);
    }

    private bool InDss(int n)
    {
        if (_dss is null)
        {
            _dss = [];
            if (_b.Catalog["DSS"] is { } dss) Reach(_b, dss, _dss, 1_000_000);
        }
        return _dss.Contains(n);
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

    private static bool Equal(PdfObject? a, PdfObject? b) => a?.ToString() == b?.ToString();

    private static IEnumerable<string> Keys(PdfDictionary a, PdfDictionary b) =>
        a.Entries.Select(e => e.Key).Concat(b.Entries.Select(e => e.Key)).Distinct();
}
