using System.Runtime.CompilerServices;
using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// One character of a shown string. Widths and vertical metrics are in 1/1000 em (for a Type 3
/// font, in glyph space scaled the same way by its /FontMatrix).
/// </summary>
/// <param name="Code">The code as read from the string.</param>
/// <param name="Length">How many bytes it took.</param>
/// <param name="Cid">The CID of a composite font; the code for a simple one.</param>
/// <param name="Width">The horizontal advance.</param>
/// <param name="Unicode">The text it stands for, null when nothing could be worked out.</param>
/// <param name="IsSpace">A single-byte code 32, the one word spacing applies to (9.3.3).</param>
/// <param name="VerticalAdvance">The advance when the font writes vertically (usually negative).</param>
/// <param name="OriginX">Where a vertical font puts the glyph origin from the horizontal one, x.</param>
/// <param name="OriginY">The same, y.</param>
public readonly record struct FontChar(int Code, int Length, int Cid, double Width, string? Unicode, bool IsSpace,
    double VerticalAdvance, double OriginX, double OriginY);

/// <summary>
/// A font dictionary understood (ISO 32000-1 9): Type1, MMType1, TrueType, Type3 and Type0 over
/// CIDFontType0 and CIDFontType2. It turns the bytes of a shown string into characters with a
/// width and a Unicode value. A broken font never throws: widths fall back to the Standard 14
/// metrics, then the descriptor's /MissingWidth, and text that cannot be traced is null.
/// </summary>
public sealed partial class PdfFont
{
    private const int MaxCached = 100_000;
    private static readonly ConditionalWeakTable<PdfDictionary, PdfFont> Cache = new();

    private readonly PdfDocument _document;
    private readonly Standard14? _std14;
    private FontProgram? _program;
    private bool _programLoaded;
    private CMap? _toUnicode;

    private PdfFont(PdfDocument document, PdfDictionary dictionary)
    {
        _document = document;
        Dictionary = dictionary;
        BaseFont = document.Name(dictionary, "BaseFont") ?? "";
        Name = BaseFont.Length > 7 && BaseFont[6] == '+' && BaseFont[..6].All(char.IsAsciiLetterUpper) ? BaseFont[7..] : BaseFont;
        string? subtype = document.Name(dictionary, "Subtype");
        Subtype = subtype is "Type1" or "MMType1" or "TrueType" or "Type3" or "Type0"
            ? subtype
            : dictionary["DescendantFonts"] is not null ? "Type0" : "Type1";
        _std14 = Standard14.Find(Name);
        try
        {
            Initialize();
        }
        catch (PdfReadException)
        {
        }
    }

    /// <summary>The font for a font dictionary of <paramref name="document"/>; the same instance each time.</summary>
    public static PdfFont Get(PdfDocument document, PdfDictionary dictionary) =>
        Cache.GetValue(dictionary, d => new PdfFont(document, d));

    public PdfDictionary Dictionary { get; }

    /// <summary>Type1, MMType1, TrueType, Type3 or Type0.</summary>
    public string Subtype { get; }

    /// <summary>/BaseFont as written, with any subset tag.</summary>
    public string BaseFont { get; }

    /// <summary>/BaseFont without the six-letter subset tag (9.6.4).</summary>
    public string Name { get; }

    public bool IsComposite => Subtype == "Type0";
    public bool IsType3 => Subtype == "Type3";

    /// <summary>The font writes top to bottom (/WMode 1 in its CMap).</summary>
    public bool IsVertical { get; private set; }

    public bool IsEmbedded { get; private set; }
    public bool HasToUnicode => _toUnicode is not null;
    public PdfDictionary? Descriptor { get; private set; }

    /// <summary>The /FontDescriptor /Flags; for a Standard 14 font without a descriptor, the flags its metrics imply.</summary>
    public int Flags { get; private set; }

    public bool IsFixedPitch => (Flags & 1) != 0;
    public bool IsSerif => (Flags & 2) != 0;
    public bool IsSymbolic => (Flags & 4) != 0 && (Flags & 32) == 0;
    public bool IsItalic { get; private set; }
    public bool IsBold { get; private set; }

    /// <summary>In 1/1000 em; the descent is negative.</summary>
    public double Ascent { get; private set; } = 800;
    public double Descent { get; private set; } = -200;
    public double CapHeight { get; private set; }

    /// <summary>The glyph space to text space matrix: 0.001 scale, or the /FontMatrix of a Type 3 font.</summary>
    public PdfMatrix FontMatrix { get; private set; } = new(0.001, 0, 0, 0.001, 0, 0);

    /// <summary>The /FontBBox in glyph space, when the font or its descriptor gives one.</summary>
    public PdfRect? FontBBox { get; private set; }

    internal FontProgram? Program
    {
        get
        {
            if (_programLoaded) return _program;
            _programLoaded = true;
            _program = FontProgram.Load(_document, Descriptor);
            return _program;
        }
    }

    private void Initialize()
    {
        var holder = Dictionary;
        if (IsComposite)
        {
            var descendants = _document.Array(Dictionary, "DescendantFonts");
            holder = descendants is { Items.Count: > 0 } ? _document.Resolve(descendants.Items[0]) as PdfDictionary ?? Dictionary : Dictionary;
        }
        Descriptor = _document.Dict(holder, "FontDescriptor");
        IsEmbedded = Descriptor is not null && (Descriptor.ContainsKey("FontFile") || Descriptor.ContainsKey("FontFile2") || Descriptor.ContainsKey("FontFile3"));
        Flags = (int?)_document.Integer(Descriptor, "Flags") ?? _std14?.Flags ?? 32;
        double angle = _document.Number(Descriptor, "ItalicAngle") ?? _std14?.ItalicAngle ?? 0;
        IsItalic = (Flags & 64) != 0 || angle != 0 || Name.Contains("Italic", StringComparison.OrdinalIgnoreCase) || Name.Contains("Oblique", StringComparison.OrdinalIgnoreCase);
        IsBold = (Flags & (1 << 18)) != 0 || Name.Contains("Bold", StringComparison.OrdinalIgnoreCase) || (_document.Number(Descriptor, "FontWeight") ?? 0) >= 700 || _std14?.IsBold == true;
        FontBBox = _document.Rect(Descriptor, "FontBBox") ?? (_std14 is { } s ? new PdfRect(s.BBox.Left, s.BBox.Bottom, s.BBox.Right, s.BBox.Top) : null);
        CapHeight = _document.Number(Descriptor, "CapHeight") ?? _std14?.CapHeight ?? 0;
        double ascent = _document.Number(Descriptor, "Ascent") ?? _std14?.Ascent ?? 0;
        double descent = _document.Number(Descriptor, "Descent") ?? _std14?.Descent ?? 0;
        if (ascent == 0 && descent == 0 && FontBBox is { } box)
        {
            ascent = box.Top;
            descent = box.Bottom;
        }
        if (ascent != 0 || descent != 0)
        {
            Ascent = ascent;
            Descent = descent > 0 ? -descent : descent;
        }
        try
        {
            if (IsComposite) InitializeComposite(holder);
            else InitializeSimple();
        }
        finally
        {
            LoadToUnicode();
        }
    }

    // Apart from the metrics, so that a damaged map costs the text and nothing else.
    private void LoadToUnicode()
    {
        try
        {
            if (_document.Stream(Dictionary, "ToUnicode") is { } stream) _toUnicode = CMap.Parse(_document.Data(stream, 16 << 20));
        }
        catch (PdfReadException)
        {
        }
    }

    // A ToUnicode map is often written at another code width than the font reads, so a miss at the
    // exact width falls back to the numeric code at any width.
    private string? MappedText(int code, int length) =>
        _toUnicode?.UnicodeOf(code, length) is { Length: > 0 } exact ? exact
        : _toUnicode?.UnicodeOf(code, 0) is { Length: > 0 } any ? any : null;

    /// <summary>Reads the first character of <paramref name="bytes"/>; returns the bytes it took (0 for empty input).</summary>
    public int Read(ReadOnlySpan<byte> bytes, out FontChar character)
    {
        if (bytes.IsEmpty)
        {
            character = default;
            return 0;
        }
        return IsComposite ? ReadComposite(bytes, out character) : ReadSimple(bytes[0], out character);
    }

    public IReadOnlyList<FontChar> Decode(ReadOnlySpan<byte> bytes)
    {
        var result = new List<FontChar>(bytes.Length);
        while (!bytes.IsEmpty)
        {
            int used = Read(bytes, out var c);
            result.Add(c);
            bytes = bytes[used..];
        }
        return result;
    }

    /// <summary>The string as text; characters that could not be traced are left out.</summary>
    public string ToText(ReadOnlySpan<byte> bytes)
    {
        var sb = new StringBuilder();
        foreach (var c in Decode(bytes)) sb.Append(c.Unicode);
        return sb.ToString();
    }
}
