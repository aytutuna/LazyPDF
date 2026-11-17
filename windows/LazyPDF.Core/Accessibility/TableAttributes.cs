namespace LazyPDF.Core;

public enum TableScope { Row, Column, Both }

/// <summary>The table attributes of a cell (ISO 32000-1 14.8.5.7), from its /A dictionary with /O /Table. Null or empty means not set.</summary>
public sealed record TableAttributes(TableScope? Scope = null, IReadOnlyList<string>? Headers = null, int? RowSpan = null, int? ColSpan = null);

public sealed partial class StructureTree
{
    private const int MaxSpan = 100_000;
    private static readonly string[] TableKeys = ["Scope", "RowSpan", "ColSpan", "Headers"];

    /// <summary>
    /// The table attributes of <paramref name="element"/>. /A may be one dictionary, an array of them or an array
    /// with a revision number after each; dictionaries of other owners are skipped, a value that is not valid is
    /// not set and, when more dictionaries are for tables, the first that has a value wins.
    /// </summary>
    public TableAttributes GetTableAttributes(StructElement element)
    {
        var tables = TableDictionaries(element).Select(t => t.Dictionary).ToList();
        TableScope? scope = null;
        List<string>? headers = null;
        int? rowSpan = null, colSpan = null;
        foreach (var d in tables)
        {
            scope ??= _document.Name(d, "Scope") switch { "Row" => TableScope.Row, "Column" => TableScope.Column, "Both" => TableScope.Both, _ => null };
            rowSpan ??= Span(d, "RowSpan");
            colSpan ??= Span(d, "ColSpan");
            if (headers is null && _document.Array(d, "Headers") is { } list)
            {
                headers = list.Items.Take(MaxNodes).Select(_document.Resolve).OfType<PdfString>().Select(s => PdfText.Decode(s.Bytes)).ToList();
                if (headers.Count == 0) headers = null;
            }
        }
        return new TableAttributes(scope, headers ?? [], rowSpan, colSpan);
    }

    private int? Span(PdfDictionary d, string key) =>
        _document.Integer(d, key) is >= 1 and <= MaxSpan and var value ? (int)value : null;

    /// <summary>
    /// Writes <paramref name="attributes"/> into the first /A dictionary of <paramref name="element"/> that is for tables,
    /// adding one when there is none, and takes those values out of the later ones; dictionaries of other owners and revision numbers stay as they were.
    /// A span of 1 is the default and is not stored. What /A held that is not a dictionary or an array is dropped.
    /// </summary>
    public void SetTableAttributes(StructElement element, TableAttributes attributes)
    {
        var current = _document.Resolve(element.Dictionary["A"]);
        var items = current switch
        {
            PdfArray array => array.Items.ToList(),
            PdfDictionary => [element.Dictionary["A"]!],
            _ => new List<PdfObject>(),
        };
        int at = items.FindIndex(IsTable);
        var original = new Dictionary<string, PdfString>(StringComparer.Ordinal);
        foreach (var (dictionary, _) in TableDictionaries(element))
        {
            if (_document.Array(dictionary, "Headers") is not { } list) continue;
            foreach (var s in list.Items.Take(MaxNodes).Select(_document.Resolve).OfType<PdfString>()) original.TryAdd(PdfText.Decode(s.Bytes), s);
        }

        // Reading takes the first table dictionary that has a value, so a later one must not keep what is cleared or changed here.
        for (int i = items.Count - 1; i > at; i--)
        {
            if (!IsTable(items[i]) || _document.Resolve(items[i]) is not PdfDictionary later || !TableKeys.Any(k => later[k] is not null)) continue;
            var rest = new PdfDictionary();
            foreach (var (key, value) in later.Entries)
            {
                if (!TableKeys.Contains(key)) rest[key] = value;
            }
            if (rest.Entries.Count() == 1)
            {
                items.RemoveAt(i);
                if (i < items.Count && items[i] is PdfNumber) items.RemoveAt(i);
            }
            else
            {
                items[i] = rest;
            }
        }

        var table = new PdfDictionary();
        if (at >= 0 && _document.Resolve(items[at]) is PdfDictionary old)
        {
            foreach (var (key, value) in old.Entries) table[key] = value;
        }
        table["O"] = new PdfName("Table");
        PutName(table, "Scope", attributes.Scope?.ToString());
        PutNumber(table, "RowSpan", attributes.RowSpan);
        PutNumber(table, "ColSpan", attributes.ColSpan);
        if (attributes.Headers is { Count: > 0 } headers) table["Headers"] = new PdfArray(headers.Select(h => original.TryGetValue(h, out var kept) ? kept : (PdfObject)PdfText.ToObject(h)).ToList());
        else table.Remove("Headers");

        bool empty = table.Entries.Count() == 1;
        if (at >= 0)
        {
            if (empty)
            {
                items.RemoveAt(at);
                if (at < items.Count && items[at] is PdfNumber) items.RemoveAt(at);
            }
            else
            {
                items[at] = table;
            }
        }
        else if (!empty)
        {
            items.Add(table);
        }

        PdfObject? result = items.Count == 0 ? null : current is PdfArray || items.Count > 1 ? new PdfArray(items) : items[0];
        if (result?.ToString() == current?.ToString()) return;
        if (result is null) element.Dictionary.Remove("A");
        else element.Dictionary["A"] = result;
    }

    private bool IsTable(PdfObject item) => _document.Resolve(item) is PdfDictionary d && _document.Name(d, "O") == "Table";

    private List<(PdfDictionary Dictionary, int Index)> TableDictionaries(StructElement element)
    {
        var found = new List<(PdfDictionary, int)>();
        var attributes = _document.Resolve(element.Dictionary["A"]);
        if (attributes is PdfDictionary single && IsTable(single)) found.Add((single, 0));
        else if (attributes is PdfArray array)
        {
            for (int i = 0; i < array.Items.Count && i < MaxNodes; i++)
            {
                if (_document.Resolve(array.Items[i]) is PdfDictionary d && IsTable(d)) found.Add((d, i));
            }
        }
        return found;
    }

    private static void PutName(PdfDictionary d, string key, string? value)
    {
        if (value is null) d.Remove(key);
        else d[key] = new PdfName(value);
    }

    private static void PutNumber(PdfDictionary d, string key, int? value)
    {
        if (value is > 1) d[key] = new PdfNumber(value.Value);
        else d.Remove(key);
    }

    /// <summary>
    /// Makes <paramref name="headers"/> the header cells of <paramref name="cell"/> (/Headers). A header without an ID
    /// gets one that no element has, since /Headers names IDs.
    /// </summary>
    public void SetHeaders(StructElement cell, IReadOnlyList<StructElement> headers)
    {
        var used = new HashSet<string>(Elements.Select(e => e.Id).OfType<string>().Where(id => id.Length > 0), StringComparer.Ordinal);
        int next = 1;
        var ids = new List<string>();
        foreach (var header in headers)
        {
            if (string.IsNullOrEmpty(header.Id))
            {
                while (!used.Add("th" + next)) next++;
                header.Id = "th" + next;
            }
            ids.Add(header.Id);
        }
        SetTableAttributes(cell, GetTableAttributes(cell) with { Headers = ids });
    }

    /// <summary>
    /// Turns the cells of a row into header cells with Scope Column: a TD becomes a TH, a cell that is a TH already
    /// keeps its type. Returns how many cells there are; 0 when <paramref name="row"/> is not a TR.
    /// </summary>
    public int MakeHeaderRow(StructElement row)
    {
        if (StandardType(row.Type) != "TR") return 0;
        int count = 0;
        foreach (var cell in row.Children)
        {
            string type = StandardType(cell.Type);
            if (type is not ("TD" or "TH")) continue;
            if (type == "TD") cell.Type = "TH";
            SetTableAttributes(cell, GetTableAttributes(cell) with { Scope = TableScope.Column });
            count++;
        }
        return count;
    }
}
