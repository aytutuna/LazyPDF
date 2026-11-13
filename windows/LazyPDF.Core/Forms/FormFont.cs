using System.Buffers;
using System.Text;

namespace LazyPDF.Core;

/// <summary>A font a field's text is set in: one of the form's /DR fonts, or one added for text those cannot show.</summary>
internal sealed class FormFont
{
    private readonly PdfDrawFont? _added;
    private readonly Dictionary<int, (int Code, double Width)>? _codes;

    private FormFont(string name, PdfReference reference, double ascent, double descent, PdfDrawFont? added, Dictionary<int, (int, double)>? codes)
    {
        Name = name;
        Reference = reference;
        Ascent = ascent;
        Descent = descent;
        _added = added;
        _codes = codes;
    }

    public string Name { get; }
    public PdfReference Reference { get; }

    /// <summary>In em; the descent is negative.</summary>
    public double Ascent { get; }
    public double Descent { get; }

    public double LineHeight(double size) => (Ascent - Descent) * size;

    /// <summary>
    /// A simple font of the form's resources, or null for one the text cannot be encoded for: Type0
    /// and Type3 fonts. The characters it can show are those its encoding gives a Unicode value.
    /// </summary>
    public static FormFont? FromResource(PdfDocument document, string name, PdfDictionary resources)
    {
        var fonts = document.Dict(resources, "Font");
        if (fonts?[name] is not { } entry || document.Resolve(entry) is not PdfDictionary dictionary) return null;
        var reference = entry as PdfReference;
        if (reference is null)
        {
            reference = document.Add(dictionary);
            fonts[name] = reference;
        }
        var font = PdfFont.Get(document, dictionary);
        if (font.IsComposite || font.IsType3) return null;
        var codes = new Dictionary<int, (int, double)>();
        Span<byte> one = stackalloc byte[1];
        for (int code = 32; code < 256; code++)
        {
            one[0] = (byte)code;
            font.Read(one, out var c);
            if (c.Unicode is { Length: > 0 } text && Rune.DecodeFromUtf16(text, out var rune, out int used) == OperationStatus.Done && used == text.Length) codes.TryAdd(rune.Value, (code, c.Width));
        }
        if (!codes.ContainsKey(0xA0) && codes.TryGetValue(' ', out var space)) codes[0xA0] = space;
        double ascent = font.Ascent > 0 ? font.Ascent / 1000 : 0.8;
        double descent = font.Descent < 0 ? font.Descent / 1000 : -0.2;
        return new FormFont(name, reference, ascent, descent, null, codes);
    }

    public static FormFont FromAdded(string name, PdfDrawFont font) =>
        new(name, font.Reference, font.Ascent, font.Descent, font, null);

    public bool CanShow(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 0x20) continue;
            if (_codes is not null ? !_codes.ContainsKey(rune.Value) : _added!.Missing.Contains(rune.Value)) return false;
        }
        return true;
    }

    /// <summary>Shows the text in display order, shaped when the font was added for it.</summary>
    public ContentWriter Show(ContentWriter writer, string text, double size) =>
        _added is not null ? writer.Show(_added, text, size) : text.Length == 0 ? writer : writer.Show(Encode(text));

    public byte[] Encode(string text)
    {
        if (_added is not null) return _added.Encode(text);
        var bytes = new List<byte>(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value >= 0x20 && _codes!.TryGetValue(rune.Value, out var c)) bytes.Add((byte)c.Code);
        }
        return [.. bytes];
    }

    public double Width(string text, double size)
    {
        if (_added is not null) return _added.Width(text, size);
        double units = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value >= 0x20 && _codes!.TryGetValue(rune.Value, out var c)) units += c.Width;
        }
        return units * size / 1000;
    }

    /// <summary>Lines no wider than <paramref name="maxWidth"/>: broken at spaces and newlines, a word wider than the box at the character.</summary>
    public IReadOnlyList<string> Wrap(string text, double size, double maxWidth)
    {
        var lines = new List<string>();
        foreach (string paragraph in text.ReplaceLineEndings("\n").Split('\n'))
        {
            var line = new StringBuilder();
            foreach (string word in paragraph.Split(' '))
            {
                string joined = line.Length == 0 ? word : line + " " + word;
                if (Width(joined, size) <= maxWidth)
                {
                    line.Clear().Append(joined);
                    continue;
                }
                if (line.Length > 0)
                {
                    lines.Add(line.ToString());
                    line.Clear();
                }
                foreach (var rune in word.EnumerateRunes())
                {
                    if (line.Length > 0 && Width(line + rune.ToString(), size) > maxWidth)
                    {
                        lines.Add(line.ToString());
                        line.Clear();
                    }
                    line.Append(rune.ToString());
                }
            }
            lines.Add(line.ToString());
        }
        return lines;
    }

    /// <summary>The family and style to look a replacement up by: the form font's own name, without the PostScript decoration.</summary>
    public static (string Family, FontStyles Style) FamilyOf(PdfDocument document, PdfDictionary resources, string name)
    {
        var fonts = document.Dict(resources, "Font");
        if (fonts is null || document.Resolve(fonts[name]) is not PdfDictionary dictionary) return ("Helvetica", FontStyles.Regular);
        var font = PdfFont.Get(document, dictionary);
        string family = font.Name.Split('-', ',')[0];
        foreach (string suffix in (ReadOnlySpan<string>)["PSMT", "MT", "PS"])
        {
            if (family.EndsWith(suffix, StringComparison.Ordinal) && family.Length > suffix.Length)
            {
                family = family[..^suffix.Length];
                break;
            }
        }
        var style = (font.IsBold ? FontStyles.Bold : 0) | (font.IsItalic ? FontStyles.Italic : 0);
        return (family.Length == 0 ? "Helvetica" : family, style);
    }
}
