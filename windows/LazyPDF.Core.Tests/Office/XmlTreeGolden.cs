using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Office/XmlTreeGolden.swift. The input format is at the top of xml-input.txt.
internal static class XmlTreeGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            output.Append("> ").Append(line).Append('\n');
            int space = line.IndexOf(' ');
            string op = line[..space];
            string rest = line[(space + 1)..];
            XmlLimits? limits = null;
            if (op == "limits")
            {
                string[] w = rest.Split(' ', 4);
                limits = new XmlLimits(int.Parse(w[0]), int.Parse(w[1]), int.Parse(w[2]));
                rest = w[3];
            }
            try
            {
                Dump(XmlTree.Parse(Golden.Unescape(rest), limits), 0, output);
            }
            catch (PdfReadException e)
            {
                output.Append("< error ").Append(e.Problem).Append('\n');
            }
        }
        return output.ToString();
    }

    private static void Dump(XmlElement e, int depth, StringBuilder o)
    {
        string pad = new(' ', depth * 2);
        o.Append("< ").Append(pad).Append("E {").Append(e.Uri).Append('}').Append(e.Name).Append('\n');
        foreach (var a in e.Attributes)
            o.Append("< ").Append(pad).Append("  A {").Append(a.Uri).Append('}').Append(a.Name).Append("=\"").Append(Esc(a.Value)).Append("\"\n");
        foreach (var n in e.Children)
        {
            if (n is XmlElement child) Dump(child, depth + 1, o);
            else o.Append("< ").Append(pad).Append("  T \"").Append(Esc(((XmlText)n).Value)).Append("\"\n");
        }
    }

    private static string Esc(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("X4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }
}
