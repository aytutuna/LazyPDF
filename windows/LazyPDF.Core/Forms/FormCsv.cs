using System.Text;

namespace LazyPDF.Core;

/// <summary>Comma-separated values as RFC 4180 describes them, read with the delimiter a spreadsheet chose (comma, semicolon or tab).</summary>
internal static class FormCsv
{
    private const int MaxRows = 100_000;
    private const int MaxColumns = 10_000;

    public static List<List<string>> Read(string text)
    {
        if (text.StartsWith('﻿')) text = text[1..];
        char delimiter = Delimiter(text);
        var rows = new List<List<string>>();
        var row = new List<string>();
        var cell = new StringBuilder();
        bool quoted = false, wasQuoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (quoted)
            {
                if (c != '"') cell.Append(c);
                else if (i + 1 < text.Length && text[i + 1] == '"')
                {
                    cell.Append('"');
                    i++;
                }
                else quoted = false;
            }
            else if (c == '"' && cell.Length == 0)
            {
                quoted = wasQuoted = true;
            }
            else if (c == delimiter)
            {
                EndCell(row, cell);
                wasQuoted = false;
            }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                EndCell(row, cell);
                if (row.Count > 1 || row[0].Length > 0 || wasQuoted) rows.Add(row);
                row = [];
                wasQuoted = false;
                if (rows.Count >= MaxRows) return rows;
            }
            else cell.Append(c);
        }
        if (cell.Length > 0 || row.Count > 0 || wasQuoted)
        {
            EndCell(row, cell);
            rows.Add(row);
        }
        return rows;
    }

    public static string Write(IEnumerable<IEnumerable<string>> rows) =>
        string.Concat(rows.Select(r => string.Join(',', r.Select(Quote)) + "\r\n"));

    private static void EndCell(List<string> row, StringBuilder cell)
    {
        if (row.Count < MaxColumns) row.Add(cell.ToString());
        cell.Clear();
    }

    private static string Quote(string value) =>
        value.IndexOfAny([',', '"', '\r', '\n']) >= 0 || value.StartsWith(' ') || value.EndsWith(' ') ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;

    // The first line decides: whichever of the three it has most of outside quotes.
    private static char Delimiter(string text)
    {
        int comma = 0, semicolon = 0, tab = 0;
        bool quoted = false;
        foreach (char c in text)
        {
            if (c == '"') quoted = !quoted;
            else if (!quoted && c is '\r' or '\n') break;
            else if (!quoted)
            {
                if (c == ',') comma++;
                else if (c == ';') semicolon++;
                else if (c == '\t') tab++;
            }
        }
        return semicolon > comma && semicolon >= tab ? ';' : tab > comma ? '\t' : ',';
    }
}
