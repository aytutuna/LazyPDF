using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

// What each kind of object may change into (ISO 32000-1 12.8.2.2 and 12.7.4.5). Each table names the keys that may
// differ at a level; a key it does not name is not allowed.
internal sealed partial class ChangeDetector
{
    private void Catalog(int n, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            switch (key)
            {
                case "DSS" or "Extensions" or "Version":
                    Report(SignatureChangeKind.ValidationData, n);
                    break;
                case "AcroForm":
                    CatalogForm(n, a[key], b[key]);
                    break;
                case "Metadata":
                    Report(SignatureChangeKind.Metadata, n);
                    break;
                case "Perms":
                    Report(SignatureChangeKind.Signature, n, allowed: false);
                    break;
                default:
                    Report(SignatureChangeKind.PageStructure, n, allowed: false);
                    break;
            }
        }
    }

    // The same indirect object is compared when it comes up on its own; another generation reads as nothing.
    private void CatalogForm(int n, PdfObject? before, PdfObject? after)
    {
        if (before is PdfReference r1 && after is PdfReference r2 && r1.Number == r2.Number)
        {
            Report(SignatureChangeKind.Form, n, allowed: false);
            return;
        }
        var a = before is null ? new PdfDictionary() : _a.Resolve(before) as PdfDictionary;
        var b = _b.Resolve(after) as PdfDictionary;
        if (a is null || b is null) Report(SignatureChangeKind.Form, n, allowed: false);
        else AcroForm(n, a, b);
    }

    private void AcroForm(int n, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            switch (key)
            {
                case "Fields" when a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number:
                    Report(SignatureChangeKind.Form, n, allowed: false);
                    break;
                case "Fields":
                    FieldsDiff((_a.Resolve(a[key]) as PdfArray)?.Items ?? [], (_b.Resolve(b[key]) as PdfArray)?.Items ?? []);
                    break;
                case "SigFlags":
                    Report(SignatureChangeKind.Signature, n, allowed: true);
                    break;
                case "DR":
                    Report(SignatureChangeKind.FormFill, n, allowed: DefaultsAllowed(Grown(a[key], b[key], 0)));
                    break;
                case "NeedAppearances" or "DA" or "Q":
                    Report(SignatureChangeKind.FormFill, n, allowed: DefaultsAllowed(false));
                    break;
                default:
                    Report(SignatureChangeKind.Form, n, allowed: false);
                    break;
            }
        }
    }

    private void Page(int n, int index, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (Equal(a, b, key)) continue;
            if (key != "Annots")
            {
                Report(key is "Contents" or "Resources" ? SignatureChangeKind.PageContent : SignatureChangeKind.PageStructure, n, index, allowed: false);
            }
            else if (a[key] is PdfReference ra && b[key] is PdfReference rb && ra.Number == rb.Number
                || a[key] is not (null or PdfReference or PdfArray) || b[key] is not (null or PdfReference or PdfArray))
            {
                Report(SignatureChangeKind.PageStructure, n, index, allowed: false);
            }
            else
            {
                AnnotsDiff((_a.Resolve(a[key]) as PdfArray)?.Items ?? [], (_b.Resolve(b[key]) as PdfArray)?.Items ?? [], index);
            }
        }
    }

    // What a comment may say, show and where it sits (12.5.2, 12.5.6), and no action, destination, layer or tag; it may
    // not become another kind of annotation.
    private static readonly HashSet<string> CommentKeys =
    [
        "Type", "Contents", "M", "NM", "C", "CA", "F", "Rect", "Border", "BS", "BE", "RD", "T", "Subj", "RC", "CreationDate",
        "IC", "QuadPoints", "L", "LE", "LL", "LLE", "LLO", "CP", "Cap", "CO", "Measure", "CL", "IT", "Name", "Open", "State", "StateModel",
        "Vertices", "InkList", "DA", "DS", "Q", "Popup", "Parent", "IRT", "RT", "P", "AP", "AS", "Sy", "RO", "OverlayText", "Repeat",
    ];

    private void Comment(int n, int page, PdfDictionary a, PdfDictionary b)
    {
        foreach (string key in Keys(a, b))
        {
            if (!Equal(a, b, key)) Report(SignatureChangeKind.Comment, n, page, allowed: CommentKeys.Contains(key) && Permits(SignatureChangeKind.Comment));
        }
    }

    private void AddedComment(int n, int page) =>
        Report(SignatureChangeKind.Comment, n, page, allowed: IsComment(_b.Get(n)) && Permits(SignatureChangeKind.Comment));

    private static bool IsComment(PdfObject? value) =>
        value is PdfDictionary comment && comment.Entries.All(e => e.Key == "Subtype" || CommentKeys.Contains(e.Key));

    // The dates and producer a tool rewrites whenever it saves are not what the signer read, so they pass at every level.
    private void Information(int n, PdfDictionary? a, PdfDictionary? b)
    {
        bool stamp = a is not null && b is not null && Keys(a, b).All(k => Equal(a, b, k) || k is "ModDate" or "Producer");
        Report(SignatureChangeKind.Metadata, n, allowed: stamp || Permits(SignatureChangeKind.Metadata));
    }

    // The same dates and producer in the XMP packet, which a tool that rewrites them in the information rewrites here too.
    private static readonly Regex Stamped = new(@"\s(?:xmp:(?:ModifyDate|MetadataDate)|pdf:Producer)=""[^""]*""|<(xmp:(?:ModifyDate|MetadataDate)|pdf:Producer)>[^<]*</\1>",
        RegexOptions.None, TimeSpan.FromSeconds(2));

    private void Packet(int n, PdfStream a, PdfStream b)
    {
        bool stamp = Keys(a.Dictionary, b.Dictionary).All(k => k is "Length" or "Filter" or "DecodeParms" || Equal(a.Dictionary, b.Dictionary, k))
            && Stamped.Replace(Encoding.Latin1.GetString(_a.Data(a)), "") == Stamped.Replace(Encoding.Latin1.GetString(_b.Data(b)), "");
        Report(SignatureChangeKind.Metadata, n, allowed: stamp || Permits(SignatureChangeKind.Metadata));
    }

    // Validation data only grows into the shapes ETSI EN 319 142-1 5.4 gives it: /DSS and /VRI with the entries named, lists and streams of data.
    private void Validation(int n, int depth, PdfObject before, PdfObject after)
    {
        if (before is PdfDictionary a && after is PdfDictionary b && depth < 3)
        {
            foreach (string key in Keys(a, b))
            {
                bool known = depth switch
                {
                    0 => key is "Type" or "VRI" or "Certs" or "OCSPs" or "CRLs",
                    1 => key.Length == 40 && key.All(char.IsAsciiHexDigit),
                    _ => key is "Type" or "Cert" or "OCSP" or "CRL" or "TU" or "TS",
                };
                if (!Equal(a, b, key)) Report(known ? SignatureChangeKind.ValidationData : SignatureChangeKind.Other, n, allowed: known);
            }
        }
        else if (depth < 3)
        {
            Report(SignatureChangeKind.Other, n, allowed: false);
        }
        else
        {
            Report(SignatureChangeKind.ValidationData, n);
        }
    }

    private void FieldsDiff(List<PdfObject> before, List<PdfObject> after)
    {
        var old = before.OfType<PdfReference>().ToHashSet();
        var kept = after.OfType<PdfReference>().ToHashSet();
        foreach (var r in old.Where(r => !kept.Contains(r))) Report(SignatureChangeKind.Form, r.Number, field: _jobsA.Fields.GetValueOrDefault(r.Number)?.Name, allowed: false);
        // A field the update makes is judged as a new object; one that was there already cannot be listed again.
        foreach (var r in kept.Where(r => !old.Contains(r) && IsListed(_a.Entries.GetValueOrDefault(r.Number)))) Report(SignatureChangeKind.Form, r.Number, allowed: false);
        if (DirectChanged(before, after) || Reordered(before, after)) Report(SignatureChangeKind.Form, 0, allowed: false);
    }

    private void AnnotsDiff(List<PdfObject> before, List<PdfObject> after, int page)
    {
        var old = before.OfType<PdfReference>().ToHashSet();
        var kept = after.OfType<PdfReference>().ToHashSet();
        foreach (var r in old.Where(r => !kept.Contains(r)))
        {
            Report(IsWidget(_a, r) ? SignatureChangeKind.Form : SignatureChangeKind.Comment, r.Number, page, allowed: !IsWidget(_a, r) && Permits(SignatureChangeKind.Comment));
        }
        foreach (var r in kept.Where(r => !old.Contains(r) && IsListed(_a.Entries.GetValueOrDefault(r.Number))))
        {
            bool placed = Placing(r.Number);
            Report(placed ? SignatureChangeKind.Signature : SignatureChangeKind.Form, r.Number, page, allowed: placed);
        }
        // A direct entry has no identity, so one that differs is a removed annotation and a new one, judged as an indirect one is.
        foreach (var item in Unmatched(before, after)) DirectAnnotation(_a, item, page, added: false);
        foreach (var item in Unmatched(after, before)) DirectAnnotation(_b, item, page, added: true);
        bool widgets = before.Concat(after).Any(i => i is PdfDictionary d && _a.Name(d, "Subtype") == "Widget");
        if (Reordered(before, after)) Report(widgets ? SignatureChangeKind.Form : SignatureChangeKind.Comment, 0, page, allowed: !widgets && Permits(SignatureChangeKind.Comment));
    }

    private void DirectAnnotation(PdfDocument document, PdfObject item, int page, bool added)
    {
        bool widget = item is PdfDictionary d && document.Name(d, "Subtype") == "Widget";
        bool known = !added || IsComment(item);
        Report(widget ? SignatureChangeKind.Form : SignatureChangeKind.Comment, 0, page, allowed: !widget && known && Permits(SignatureChangeKind.Comment));
    }

    // The direct entries of the first list that the second does not hold as often.
    private static IEnumerable<PdfObject> Unmatched(List<PdfObject> list, List<PdfObject> other)
    {
        var rest = other.Where(i => i is not PdfReference).Select(Text).ToList();
        return list.Where(i => i is not PdfReference && !rest.Remove(Text(i)));
    }

    // An unsigned signature field with no widget, listed on a page by the update that signs it.
    private bool Placing(int number) =>
        _jobsA.Fields.GetValueOrDefault(number) is { IsSignature: true, HasValue: false } node && _a.Get(number) is PdfDictionary was && _a.Name(was, "Subtype") != "Widget"
        && _b.Get(number) is PdfDictionary field && SignatureAdded(field) && !IsLocked(node);

    private static bool IsWidget(PdfDocument document, PdfReference r) => document.Get(r.Number) is PdfDictionary d && document.Name(d, "Subtype") == "Widget";

    private static bool DirectChanged(List<PdfObject> before, List<PdfObject> after) =>
        !before.Where(i => i is not PdfReference).Select(Text).SequenceEqual(after.Where(i => i is not PdfReference).Select(Text));

    // The order of the entries both lists hold, direct ones among them, is the stacking of annotations and the tab order of fields.
    private static bool Reordered(List<PdfObject> before, List<PdfObject> after)
    {
        var old = before.Select(Text).ToHashSet();
        var kept = after.Select(Text).ToHashSet();
        return !before.Select(Text).Where(kept.Contains).SequenceEqual(after.Select(Text).Where(old.Contains));
    }

    // Compared with every entry of a repeated key, which ToString leaves out but another parser may read.
    private static bool Equal(PdfDictionary a, PdfDictionary b, string key) => Values(a, key) == Values(b, key);

    private static string Values(PdfDictionary dictionary, string key) =>
        string.Join(' ', dictionary.Entries.Where(e => e.Key == key).Select(e => Text(e.Value)));

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
