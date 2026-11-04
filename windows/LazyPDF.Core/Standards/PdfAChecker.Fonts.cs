namespace LazyPDF.Core;

// Fonts (ISO 19005-1 6.3, 19005-2 6.2.11): embedding, subset sets, composite font parts, TrueType
// encodings and, for level U, a path to Unicode. Widths against the font program are compared as the
// glyphs are met in the content (NoteGlyph), since only the glyphs shown matter.
internal sealed partial class PdfAChecker
{
    private static readonly string[] LatinEncodings = ["WinAnsiEncoding", "MacRomanEncoding", "MacExpertEncoding", "StandardEncoding"];

    internal IReadOnlyCollection<PdfDictionary> Fonts => _fonts;

    internal bool NeedsToUnicode(PdfFont font) => level.NeedsUnicode() && !font.HasToUnicode && !HasStandardText(font);

    private void CheckFonts()
    {
        foreach (var used in FontUses.Keys) _fonts.Add(used);
        foreach (var font in _fonts) CheckFont(font);
    }

    private void CheckFont(PdfDictionary font)
    {
        string? subtype = _doc.Name(font, "Subtype");
        var pdfFont = PdfFont.Get(_doc, font);
        string where = PdfAText.FontName(pdfFont.BaseFont);
        if (NeedsToUnicode(pdfFont)) Add(C("6.3.8", "6.2.11.7.2"), where, PdfAText.NoUnicode);
        if (subtype == "Type3") return;

        var holder = font;
        if (subtype == "Type0")
        {
            CheckComposite(font, where);
            holder = _doc.Array(font, "DescendantFonts") is { Items.Count: > 0 } kids && _doc.Resolve(kids.Items[0]) is PdfDictionary d ? d : font;
        }
        var descriptor = _doc.Dict(holder, "FontDescriptor");
        if (descriptor is null || !(descriptor.ContainsKey("FontFile") || descriptor.ContainsKey("FontFile2") || descriptor.ContainsKey("FontFile3")))
        {
            Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontNotEmbedded);
            return;
        }
        if (FontProgram.Load(_doc, descriptor) is not { } program)
        {
            Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontProgramUnreadable);
            return;
        }
        if (_doc.Stream(descriptor, "FontFile3") is { } file3 && _doc.Name(file3.Dictionary, "Subtype") is not ("Type1C" or "CIDFontType0C" or "OpenType"))
            Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontFileSubtype);

        CheckSubsetSets(pdfFont, descriptor, holder, where);
        if (subtype == "Type0") return;
        if (!font.ContainsKey("Widths") || !font.ContainsKey("FirstChar")) Add(C("6.3.6", "6.2.11.5"), where, PdfAText.NoWidths);
        if (subtype == "TrueType") CheckTrueTypeEncoding(font, descriptor, program, where);
    }

    private void CheckComposite(PdfDictionary font, string where)
    {
        string clause = C("6.3.3", "6.2.11.3");
        var encoding = _doc.Resolve(font["Encoding"]);
        if (encoding is PdfName name ? CMap.Predefined(name.Value).IsFallback : encoding is not PdfStream) Add(clause, where, PdfAText.CMapNotKnown);
        if (_doc.Array(font, "DescendantFonts") is not { Items.Count: > 0 } kids || _doc.Resolve(kids.Items[0]) is not PdfDictionary cid) return;
        if (_doc.Dict(cid, "CIDSystemInfo") is null) Add(clause, where, PdfAText.NoSystemInfo);
        bool embedded = _doc.Dict(cid, "FontDescriptor") is { } d && d.ContainsKey("FontFile2");
        if (_doc.Name(cid, "Subtype") == "CIDFontType2" && embedded && cid["CIDToGIDMap"] is null) Add(C("6.3.3.1", "6.2.11.3.2"), where, PdfAText.NoCidToGid);
    }

    // 6.3.5 / 6.2.11.4.2: a CIDSet or CharSet that is there must list what the content shows.
    private void CheckSubsetSets(PdfFont pdfFont, PdfDictionary descriptor, PdfDictionary holder, string where)
    {
        if (!FontUses.TryGetValue(pdfFont.Dictionary, out var used)) return;
        string clause = C("6.3.5", "6.2.11.4.2");
        if (_doc.Stream(descriptor, "CIDSet") is { } set)
        {
            try
            {
                byte[] bits = _doc.Data(set, 1 << 20);
                if (used.Any(cid => (cid >> 3) >= bits.Length || (bits[cid >> 3] & (0x80 >> (cid & 7))) == 0)) Add(clause, where, PdfAText.CidSetIncomplete);
            }
            catch (PdfReadException)
            {
                Add(clause, where, PdfAText.CidSetIncomplete);
            }
        }
        if (_doc.Resolve(descriptor["CharSet"]) is PdfString charSet && _doc.Name(holder, "Subtype") is "Type1" or "MMType1")
        {
            var listed = System.Text.Encoding.Latin1.GetString(charSet.Bytes).Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();
            if (used.Select(pdfFont.GlyphNameOf).Any(g => g is not (null or ".notdef") && !listed.Contains(g))) Add(clause, where, PdfAText.CharSetIncomplete);
        }
    }

    // 6.3.7 / 6.2.11.6: a symbolic TrueType font has no /Encoding and a (3,0) or (1,0) cmap; the other kind names WinAnsi or MacRoman.
    private void CheckTrueTypeEncoding(PdfDictionary font, PdfDictionary descriptor, FontProgram program, string where)
    {
        string clause = C("6.3.7", "6.2.11.6");
        long flags = _doc.Integer(descriptor, "Flags") ?? 0;
        var encoding = _doc.Resolve(font["Encoding"]);
        string? baseName = encoding switch { PdfName n => n.Value, PdfDictionary e => _doc.Name(e, "BaseEncoding"), _ => null };
        bool symbolic = (flags & 4) != 0 && (flags & 32) == 0;
        if (symbolic)
        {
            if (encoding is not null) Add(clause, where, PdfAText.SymbolicEncoding);
            if (program.TrueType is { } tt && !(tt.HasCmap(3, 0) || tt.HasCmap(1, 0))) Add(clause, where, PdfAText.SymbolicCmap);
        }
        else if (baseName is not ("WinAnsiEncoding" or "MacRomanEncoding"))
        {
            Add(clause, where, PdfAText.TrueTypeEncoding);
        }
    }

    private bool HasStandardText(PdfFont font)
    {
        if (font.IsComposite)
        {
            return _doc.Resolve(font.Dictionary["Encoding"]) is PdfName { Value: not ("Identity-H" or "Identity-V") } name && !CMap.Predefined(name.Value).IsFallback;
        }
        if (font.IsSymbolic) return false;
        switch (_doc.Resolve(font.Dictionary["Encoding"]))
        {
            case PdfName name:
                return LatinEncodings.Contains(name.Value);
            case PdfDictionary encoding:
                if (_doc.Name(encoding, "BaseEncoding") is { } baseName && !LatinEncodings.Contains(baseName)) return false;
                var differences = _doc.Array(encoding, "Differences")?.Items.Select(_doc.Resolve).OfType<PdfName>() ?? [];
                return differences.All(g => GlyphList.UnicodeOf(g.Value) is not null);
            default:
                return (font.Flags & 32) != 0;
        }
    }
}
