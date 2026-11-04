namespace LazyPDF.Core;

/// <summary>
/// One form and a CSV file of values give one PDF per data row. The first CSV row names the fields; a
/// column no field has is listed in <see cref="UnmatchedColumns"/> and skipped. An empty cell empties
/// its field. Each PDF is made from the form's original bytes, so rows do not affect each other.
/// </summary>
public sealed class BulkFill
{
    private readonly byte[] _form;
    private readonly string? _password;
    private readonly IFontSource? _fonts;
    private readonly List<string> _columns;
    private readonly List<List<string>> _rows;

    private BulkFill(byte[] form, string? password, IFontSource? fonts, List<string> columns, List<List<string>> rows, IReadOnlyList<string> unmatched)
    {
        _form = form;
        _password = password;
        _fonts = fonts;
        _columns = columns;
        _rows = rows;
        UnmatchedColumns = unmatched;
    }

    public int Rows => _rows.Count;
    public IReadOnlyList<string> Columns => _columns;
    public IReadOnlyList<string> UnmatchedColumns { get; }

    /// <summary>Reads the form and the CSV text. Throws <see cref="PdfReadException"/> as <see cref="PdfDocument.Open(byte[], string?)"/> does and for a dynamic XFA form.</summary>
    public static BulkFill Create(byte[] form, string csv, IFontSource? fonts = null, string? password = null)
    {
        var table = FormCsv.Read(csv);
        var columns = table.Count > 0 ? table[0] : [];
        var probe = PdfForm.Read(PdfDocument.Open(form, password), fonts);
        if (probe.Xfa == XfaKind.Dynamic) throw new PdfReadException(PdfReadProblem.Unsupported, FormText.DynamicXfa);
        var unmatched = columns.Where(c => c.Length > 0 && probe.Find(c) is null).Distinct().ToList();
        return new BulkFill(form, password, fonts, columns, [.. table.Skip(1)], unmatched);
    }

    /// <summary>The PDF for data row <paramref name="row"/> (from 0), written as an incremental update of the form, so a signature on it is kept; flattened when asked.</summary>
    public byte[] Fill(int row, bool flatten = false)
    {
        var values = new List<KeyValuePair<string, string?>>();
        for (int i = 0; i < _columns.Count && i < _rows[row].Count; i++)
        {
            if (_columns[i].Length > 0 && !UnmatchedColumns.Contains(_columns[i])) values.Add(new(_columns[i], _rows[row][i]));
        }
        var document = PdfDocument.Open(_form, _password);
        var form = PdfForm.Read(document, _fonts);
        form.SetValues(values);
        if (flatten) form.Flatten();
        return document.SaveIncremental();
    }
}
