using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Syntax/SyntaxGolden.swift. One line of input is "<op> <escaped
// bytes>"; the result is what the lexer or the writer made of them, in text.
internal static class SyntaxGolden
{
    public static string Lexer(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            int space = line.IndexOf(' ');
            string op = space < 0 ? line : line[..space];
            byte[] data = Golden.Unescape(space < 0 ? "" : line[(space + 1)..]);
            output.Append("> ").Append(line).Append('\n').Append("< ").Append(Run(op, data)).Append('\n');
        }
        return output.ToString();
    }

    public static string Numbers(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            double value = double.Parse(line, CultureInfo.InvariantCulture);
            output.Append(line).Append(" -> ").Append(new PdfNumber(value).Text).Append('\n');
        }
        return output.ToString();
    }

    private static string Run(string op, byte[] data)
    {
        var lexer = new PdfLexer(new PdfArrayBytes(data));
        try
        {
            switch (op)
            {
                case "object": return Describe(lexer.ReadObject(), lexer);
                case "value": return Describe(lexer.ReadObject(allowStream: false), lexer);
                case "header":
                    var (number, generation) = lexer.ReadObjectHeader();
                    return $"({number}, {generation}) pos={lexer.Position}";
                case "keyword":
                    return $"\"{Golden.Escape(lexer.ReadKeyword())}\" pos={lexer.Position}";
                case "unsigned":
                    return $"{lexer.TryReadUnsigned()?.ToString(CultureInfo.InvariantCulture) ?? "none"} pos={lexer.Position}";
                case "string":
                    var text = new PdfString(data, isHex: false);
                    string literal = text.ToString();
                    text.IsHex = true;
                    return $"{literal} {text}";
                case "name":
                    return new PdfName(Encoding.Latin1.GetString(data)).ToString();
                default:
                    throw new InvalidOperationException($"No op \"{op}\".");
            }
        }
        catch (PdfReadException e)
        {
            string problem = e.Problem.ToString();
            return $"error {char.ToLowerInvariant(problem[0])}{problem[1..]}: {Golden.Escape(e.Message)}";
        }
    }

    private static string Describe(PdfObject value, PdfLexer lexer)
    {
        string kind = value.GetType().Name;
        string written = value switch
        {
            PdfNumber n => $"{n.Text} integer={n.Integer?.ToString(CultureInfo.InvariantCulture) ?? "none"}",
            PdfStream s => $"{s.Dictionary} data@{s.DataOffset}",
            _ => value.ToString(),
        };
        return $"{kind} {Golden.Escape(written)} pos={lexer.Position}";
    }
}
