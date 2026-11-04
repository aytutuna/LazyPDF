using System.Globalization;
using System.Text;
using System.Xml;

namespace LazyPDF.Core;

/// <summary>
/// The look of a stretch of text: what /DA, /DS and the style attributes of /RC (an XHTML subset,
/// ISO 32000-1 12.7.3.4) say, merged.
/// </summary>
internal sealed record TextFormat(string Family, double Size, bool Bold, bool Italic, bool Underline, double[] Color)
{
    public static readonly TextFormat Default = new("Helvetica", 12, false, false, false, [0]);

    public FontStyles Style => (Bold ? FontStyles.Bold : 0) | (Italic ? FontStyles.Italic : 0);

    /// <summary>This format with the declarations of a CSS style attribute applied on top.</summary>
    public TextFormat WithCss(string? css)
    {
        var f = this;
        if (string.IsNullOrWhiteSpace(css)) return f;
        foreach (string declaration in css.Split(';'))
        {
            int colon = declaration.IndexOf(':');
            if (colon < 0) continue;
            string key = declaration[..colon].Trim().ToLowerInvariant();
            string value = declaration[(colon + 1)..].Trim();
            switch (key)
            {
                case "font-family": f = f with { Family = FirstFamily(value) }; break;
                case "font-size" when Length(value) is { } size: f = f with { Size = size }; break;
                case "font-weight": f = f with { Bold = value.Equals("bold", StringComparison.OrdinalIgnoreCase) || int.TryParse(value, out int w) && w >= 600 }; break;
                case "font-style": f = f with { Italic = value is "italic" or "oblique" }; break;
                case "text-decoration": f = f with { Underline = value.Contains("underline", StringComparison.OrdinalIgnoreCase) }; break;
                case "color" when HexColor(value) is { } color: f = f with { Color = color }; break;
                case "font": f = f.WithShorthand(value); break;
            }
        }
        return f;
    }

    private TextFormat WithShorthand(string value)
    {
        var f = this;
        var family = new List<string>();
        foreach (string token in value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.Equals("bold", StringComparison.OrdinalIgnoreCase)) f = f with { Bold = true };
            else if (token is "italic" or "oblique") f = f with { Italic = true };
            else if (token is "normal") continue;
            else if (Length(token) is { } size && char.IsAsciiDigit(token[0])) f = f with { Size = size };
            else family.Add(token);
        }
        return family.Count > 0 ? f with { Family = FirstFamily(string.Join(' ', family)) } : f;
    }

    private static string FirstFamily(string value)
    {
        string first = value.Split(',')[0].Trim().Trim('\'', '"');
        return first.Length > 0 ? first : "Helvetica";
    }

    private static double? Length(string value)
    {
        string number = value.EndsWith("pt", StringComparison.OrdinalIgnoreCase) || value.EndsWith("px", StringComparison.OrdinalIgnoreCase) ? value[..^2] : value;
        return double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out double size) && size is > 0 and < 1000 ? size : null;
    }

    private static double[]? HexColor(string value)
    {
        if (!value.StartsWith('#')) return null;
        string hex = value[1..];
        if (hex.Length == 3) hex = string.Concat(hex.Select(ch => new string(ch, 2)));
        if (hex.Length != 6 || !int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int rgb)) return null;
        return [(rgb >> 16 & 255) / 255.0, (rgb >> 8 & 255) / 255.0, (rgb & 255) / 255.0];
    }
}

internal sealed record TextRun(string Text, TextFormat Format);

/// <summary>Rich text at a basic level: paragraphs, line breaks, and bold, italic, underline, size, family and colour.</summary>
public static class PdfRichText
{
    private const int MaxLength = 200_000;

    /// <summary>The plain text of an /RC string: paragraphs on lines of their own. Empty for text that is not well-formed XML.</summary>
    public static string ToPlain(string xhtml) =>
        Parse(xhtml, TextFormat.Default) is { } paragraphs ? string.Join('\n', paragraphs.Select(p => string.Concat(p.Select(r => r.Text)))) : "";

    internal static List<List<TextRun>>? Parse(string xhtml, TextFormat defaults)
    {
        if (xhtml.Length > MaxLength) return null;
        var paragraphs = new List<List<TextRun>> { new() };
        var formats = new Stack<TextFormat>();
        formats.Push(defaults);
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, ConformanceLevel = ConformanceLevel.Fragment, XmlResolver = null };
        try
        {
            using var reader = XmlReader.Create(new StringReader(xhtml), settings);
            var opened = new Stack<bool>();
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        string name = reader.LocalName.ToLowerInvariant();
                        var format = formats.Peek().WithCss(reader.GetAttribute("style"));
                        format = name switch
                        {
                            "b" or "strong" => format with { Bold = true },
                            "i" or "em" => format with { Italic = true },
                            "u" => format with { Underline = true },
                            _ => format,
                        };
                        if (name == "p" && paragraphs[^1].Count > 0) paragraphs.Add([]);
                        if (name == "br") paragraphs.Add([]);
                        if (!reader.IsEmptyElement)
                        {
                            formats.Push(format);
                            opened.Push(name == "p");
                        }
                        break;
                    }
                    case XmlNodeType.EndElement:
                        if (formats.Count > 1) formats.Pop();
                        if (opened.Count > 0 && opened.Pop()) paragraphs.Add([]);
                        break;
                    case XmlNodeType.Text or XmlNodeType.SignificantWhitespace or XmlNodeType.Whitespace:
                        string text = Collapse(reader.Value);
                        // Indentation between block tags is not text; a space between two spans is.
                        if (text.Length > 0 && (paragraphs[^1].Count > 0 || text != " ")) paragraphs[^1].Add(new TextRun(text, formats.Peek()));
                        break;
                }
            }
        }
        catch (XmlException)
        {
            return null;
        }
        while (paragraphs.Count > 1 && paragraphs[^1].Count == 0) paragraphs.RemoveAt(paragraphs.Count - 1);
        return paragraphs;
    }

    private static string Collapse(string text)
    {
        var sb = new StringBuilder(text.Length);
        bool space = false;
        foreach (char c in text)
        {
            if (char.IsWhiteSpace(c))
            {
                space = true;
                continue;
            }
            if (space) sb.Append(' ');
            space = false;
            sb.Append(c);
        }
        if (space) sb.Append(' ');
        return sb.ToString();
    }
}
