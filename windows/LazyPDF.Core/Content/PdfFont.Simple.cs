namespace LazyPDF.Core;

// Simple fonts: one byte a character, the encoding gives each code a glyph name (9.6.6).
public sealed partial class PdfFont
{
    private const int MaxDifferences = 4096;

    private double[]? _widths;
    private int _firstChar;
    private double _missingWidth;
    private string?[]? _names;
    private FontChar[]? _simple;
    private bool[]? _simpleDone;

    private string?[] Names => _names ??= BuildNames();

    private void InitializeSimple()
    {
        double scale = 1;
        if (IsType3)
        {
            if (PdfMatrix.FromArray(_document.Array(Dictionary, "FontMatrix"), _document.Resolve) is { A: not 0 } matrix) FontMatrix = matrix;
            scale = FontMatrix.A * 1000;
            FontBBox = _document.Rect(Dictionary, "FontBBox");
            if (FontBBox is { } box)
            {
                Ascent = box.Top * FontMatrix.D * 1000;
                Descent = box.Bottom * FontMatrix.D * 1000;
            }
        }
        _missingWidth = (_document.Number(Descriptor, "MissingWidth") ?? 0) * scale;
        _firstChar = (int)Math.Clamp(_document.Integer(Dictionary, "FirstChar") ?? 0, 0, 255);
        if (_document.Array(Dictionary, "Widths") is { } widths)
        {
            _widths = new double[Math.Min(widths.Items.Count, 256)];
            for (int i = 0; i < _widths.Length; i++)
            {
                _widths[i] = _document.Resolve(widths.Items[i]) is PdfNumber { Value: var w } && double.IsFinite(w) ? w * scale : 0;
            }
        }
    }

    private int ReadSimple(byte code, out FontChar character)
    {
        _simple ??= new FontChar[256];
        _simpleDone ??= new bool[256];
        if (!_simpleDone[code])
        {
            double width = SimpleWidth(code);
            _simple[code] = new FontChar(code, 1, code, width, SimpleUnicode(code), code == 32, -1000, width / 2, 880);
            _simpleDone[code] = true;
        }
        character = _simple[code];
        return 1;
    }

    private double SimpleWidth(int code)
    {
        if (_widths is not null)
        {
            int index = code - _firstChar;
            return index >= 0 && index < _widths.Length ? _widths[index] : _missingWidth;
        }
        if (IsType3) return _missingWidth;
        string? name = Names[code];
        if (name is not null && _std14?.WidthOf(name) is { } standard) return standard;
        if (Program is { } program)
        {
            if (program.Width(code, name) is { } own) return own;
            if (program.TrueType is { Cff: null } tt && TrueTypeGlyph(tt, code) is > 0 and var gid) return tt.GetAdvance(gid) * 1000.0 / tt.UnitsPerEm;
        }
        // No widths and no font to ask: the metrics a viewer would substitute.
        if (_std14 is null && name is not null && Substitute().WidthOf(name) is { } substitute) return substitute;
        return _missingWidth;
    }

    private Standard14 Substitute()
    {
        string family = IsFixedPitch ? "Courier" : IsSerif ? "Times" : "Helvetica";
        return Standard14.Find(IsBold ? family + "-Bold" : family == "Times" ? "Times-Roman" : family)!;
    }

    private string? SimpleUnicode(int code)
    {
        if (MappedText(code, 1) is { } mapped) return mapped;
        string? name = Names[code];
        if (name is not null && GlyphList.UnicodeOf(name) is { } fromName) return fromName;
        if (Program is not { } program) return null;
        if (program.TrueType is { Cff: null } tt) return TrueTypeGlyph(tt, code) is > 0 and var gid ? program.UnicodeOf(gid) : null;
        return program.BuiltInName(code) is { } builtIn ? GlyphList.UnicodeOf(builtIn) : null;
    }

    // 9.6.6.4: a symbolic font's cmap is read by code, (3,0) at 0xF000 and up, or (1,0).
    private int TrueTypeGlyph(TrueTypeFont tt, int code)
    {
        if (Names[code] is { } name && GlyphList.UnicodeOf(name) is { Length: > 0 } text)
        {
            int glyph = tt.GlyphForCodePoint(char.ConvertToUtf32(text, 0));
            if (glyph > 0) return glyph;
        }
        int gid = tt.GlyphForCmap(3, 0, code);
        if (gid == 0) gid = tt.GlyphForCmap(3, 0, 0xF000 + code);
        if (gid == 0) gid = tt.GlyphForCmap(1, 0, code);
        if (gid == 0) gid = tt.GlyphForCodePoint(code);
        return gid;
    }

    private string?[] BuildNames()
    {
        var names = new string?[256];
        IReadOnlyList<string?>? table = null;
        PdfArray? differences = null;
        switch (_document.Resolve(Dictionary["Encoding"]))
        {
            case PdfName encoding:
                table = PdfEncodings.ByName(encoding.Value);
                break;
            case PdfDictionary encoding:
                if (_document.Name(encoding, "BaseEncoding") is { } baseName) table = PdfEncodings.ByName(baseName);
                differences = _document.Array(encoding, "Differences");
                break;
        }
        table ??= DefaultEncoding();
        if (table is not null)
        {
            for (int i = 0; i < 256; i++) names[i] = table[i];
        }
        if (differences is not null)
        {
            int code = 0;
            foreach (var item in differences.Items.Take(MaxDifferences))
            {
                switch (_document.Resolve(item))
                {
                    case PdfNumber number:
                        code = (int)Math.Clamp(number.Value, -1, 1000);
                        break;
                    case PdfName glyph:
                        if ((uint)code < 256) names[code] = glyph.Value;
                        code++;
                        break;
                }
            }
        }
        return names;
    }

    // 9.6.6.1: with no base encoding a symbolic or embedded font uses its own.
    private IReadOnlyList<string?>? DefaultEncoding()
    {
        if (_std14 is { IsSymbolic: true }) return _std14.BuiltInEncoding;
        if (IsEmbedded && Program is { } program && Subtype != "TrueType")
        {
            var own = new string?[256];
            for (int i = 0; i < 256; i++) own[i] = program.BuiltInName(i);
            if (own.Any(n => n is not null)) return own;
        }
        if (Subtype == "TrueType") return IsSymbolic && IsEmbedded ? null : PdfEncodings.WinAnsi;
        return PdfEncodings.Standard;
    }
}
