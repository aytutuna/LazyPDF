using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

public enum DataFormat
{
    Fdf,
    Xfdf,
    Csv,
    Json,
}

/// <summary>The values of a form in the four files people exchange them in.</summary>
internal static class FormData
{
    public static DataFormat? FormatOf(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".fdf" => DataFormat.Fdf,
        ".xfdf" => DataFormat.Xfdf,
        ".csv" => DataFormat.Csv,
        ".json" => DataFormat.Json,
        _ => null,
    };

    public static byte[] Export(PdfForm form, DataFormat format, string fileName) => format switch
    {
        DataFormat.Fdf => PdfFdf.Write(form.ExportFdf(fileName)),
        DataFormat.Xfdf => PdfXfdf.Write(form.ExportFdf(fileName)),
        // The mark lets Excel read Turkish letters.
        DataFormat.Csv => [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(form.ExportCsv())],
        _ => ToJson(form),
    };

    /// <summary>Fills the form from a file. <paramref name="rows"/> is how many data rows a CSV file had; only the first is used.</summary>
    public static FormFillResult Import(PdfForm form, DataFormat format, byte[] data, out int rows)
    {
        rows = 1;
        switch (format)
        {
            case DataFormat.Fdf:
                return form.ImportFdf(PdfFdf.Read(data));
            case DataFormat.Xfdf:
                return form.ImportFdf(PdfXfdf.Read(data));
            case DataFormat.Csv:
                var table = ParseCsv(CsvText(data));
                if (table.Count < 2) throw new FormatException("The table has no data row.");
                rows = table.Count - 1;
                return form.SetValues(table[0].Zip(table[1], (name, value) => new KeyValuePair<string, string?>(name, value)).Where(p => p.Key.Length > 0));
            default:
                return form.SetValues(FromJson(data));
        }
    }

    // Excel saves a Turkish CSV in the ANSI code page unless it is told otherwise.
    private static string CsvText(byte[] data)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(data).TrimStart('\ufeff');
        }
        catch (DecoderFallbackException)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1254).GetString(data);
        }
    }

    private static byte[] ToJson(PdfForm form)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            var fields = form.Fields.Where(f => f.Kind is not (FieldKind.PushButton or FieldKind.Signature) && !f.Has(FieldFlags.NoExport));
            foreach (var field in fields.GroupBy(f => f.Name).Select(g => g.First()))
            {
                writer.WriteString(field.Name, field.Selected.Count > 1 ? string.Join("; ", field.Selected) : field.Value ?? "");
            }
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static List<KeyValuePair<string, string?>> FromJson(byte[] data)
    {
        using var json = JsonDocument.Parse(data, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip });
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("The file is not an object of names and values.");
        var values = new List<KeyValuePair<string, string?>>();
        foreach (var property in json.RootElement.EnumerateObject())
        {
            string? text = property.Value.ValueKind switch
            {
                JsonValueKind.String => property.Value.GetString(),
                JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => property.Value.GetRawText(),
                JsonValueKind.Array => string.Join("; ", property.Value.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString() : e.GetRawText())),
                _ => null,
            };
            if (text is not null) values.Add(new(property.Name, text));
        }
        return values;
    }

    // Comma, semicolon or tab, whichever the first line uses most; quotes may hold the separator and line breaks.
    internal static List<List<string>> ParseCsv(string text)
    {
        int end = text.IndexOfAny(['\r', '\n']);
        string first = end < 0 ? text : text[..end];
        char separator = new[] { ',', ';', '\t' }.MaxBy(c => first.Count(x => x == c));
        var rows = new List<List<string>>();
        var row = new List<string>();
        var cell = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (quoted)
            {
                if (c != '"') cell.Append(c);
                else if (i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                else quoted = false;
            }
            else if (c == '"') quoted = true;
            else if (c == separator) { row.Add(cell.ToString()); cell.Clear(); }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(cell.ToString());
                cell.Clear();
                rows.Add(row);
                row = [];
            }
            else cell.Append(c);
        }
        if (cell.Length > 0 || row.Count > 0)
        {
            row.Add(cell.ToString());
            rows.Add(row);
        }
        return rows;
    }
}
