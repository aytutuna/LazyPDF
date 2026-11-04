namespace LazyPDF.Core;

// Fonts (ISO 19005-1 6.3, 19005-2 6.2.11): embedding, subset sets, composite font parts, TrueType
// encodings and, for level U, a path to Unicode. Only fonts that show a glyph are held to these rules,
// and widths against the font program are compared as the glyphs are met in the content (NoteGlyph).
internal sealed partial class PdfAChecker
{
    private static readonly string[] LatinEncodings = ["WinAnsiEncoding", "MacRomanEncoding", "MacExpertEncoding", "StandardEncoding"];

    internal IReadOnlyCollection<PdfDictionary> Fonts => FontUses.Keys;

    internal bool NeedsToUnicode(PdfFont font) => level.NeedsUnicode() && !font.HasToUnicode && !HasStandardText(font);

    private void CheckFonts()
    {
        foreach (var font in FontUses.Keys) CheckFont(font);
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
            // Parts 2 and later exempt a font that is only used with text rendering mode 3 (6.2.11.4.1).
            if (IsPart1 || _renderedFonts.Contains(font)) Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontNotEmbedded);
            return;
        }
        if (FontProgram.Load(_doc, descriptor) is not { } program)
        {
            Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontProgramUnreadable);
            return;
        }
        if (_doc.Stream(descriptor, "FontFile3") is { } file3)
        {
            // OpenType font files came with PDF 1.6.
            string? kind = _doc.Name(file3.Dictionary, "Subtype");
            if (!(kind is "Type1C" or "CIDFontType0C" || (kind == "OpenType" && !IsPart1))) Add(C("6.3.4", "6.2.11.4.1"), where, PdfAText.FontFileSubtype);
        }

        CheckSubsetSets(pdfFont, descriptor, holder, program, where);
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
        if (_doc.Name(cid, "Subtype") == "CIDFontType2" && embedded && cid["CIDToGIDMap"] is null) Add(C("6.3.3.2", "6.2.11.3.2"), where, PdfAText.NoCidToGid);
    }

    // 6.3.5 / 6.2.11.4.2: a CIDSet or CharSet that is there lists every glyph the font program holds, the ones shown among them. Part 1
    // speaks of subsets only and asks for one in each; from part 2 any embedded font that has one is held to it.
    private void CheckSubsetSets(PdfFont pdfFont, PdfDictionary descriptor, PdfDictionary holder, FontProgram program, string where)
    {
        if (IsPart1 && !IsSubset(descriptor, holder)) return;
        var used = FontUses[pdfFont.Dictionary];
        string clause = C("6.3.5", "6.2.11.4.2");
        bool required = IsPart1;
        if (holder != pdfFont.Dictionary)
        {
            if (_doc.Stream(descriptor, "CIDSet") is not { } set)
            {
                if (required) Add(clause, where, PdfAText.CidSetMissing);
            }
            else if (!ListsAll(set, used.Concat(ProgramCids(holder, program))))
            {
                Add(clause, where, PdfAText.CidSetIncomplete);
            }
        }
        else if (_doc.Name(holder, "Subtype") is "Type1" or "MMType1")
        {
            if (_doc.Resolve(descriptor["CharSet"]) is not PdfString charSet)
            {
                if (required) Add(clause, where, PdfAText.CharSetMissing);
                return;
            }
            var listed = System.Text.Encoding.Latin1.GetString(charSet.Bytes).Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();
            var shown = used.Select(pdfFont.GlyphNameOf).OfType<string>();
            if (shown.Concat(ProgramGlyphNames(program)).Any(g => g != ".notdef" && !listed.Contains(g))) Add(clause, where, PdfAText.CharSetIncomplete);
        }
    }

    // A subset name starts with six capital letters and a plus sign (ISO 32000-1 9.6.4).
    private bool IsSubset(PdfDictionary descriptor, PdfDictionary holder) =>
        (_doc.Name(descriptor, "FontName") ?? _doc.Name(holder, "BaseFont")) is { Length: > 7 } name && name[6] == '+' && name.AsSpan(0, 6).IndexOfAnyExceptInRange('A', 'Z') < 0;

    private bool ListsAll(PdfStream set, IEnumerable<int> cids)
    {
        try
        {
            byte[] bits = _doc.Data(set, 1 << 20);
            return cids.All(cid => (cid >> 3) < bits.Length && (bits[cid >> 3] & (0x80 >> (cid & 7))) != 0);
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    // The CIDs of the glyphs a program draws: the empty slots of a subset TrueType font do not count.
    private List<int> ProgramCids(PdfDictionary cidFont, FontProgram program)
    {
        var cids = new List<int>();
        if (program.Cff is { } cff)
        {
            for (int gid = 1; gid < cff.GlyphCount; gid++) cids.Add(cff.CidForGlyph(gid));
        }
        else if (program.TrueType is { } tt)
        {
            byte[]? map = null;
            if (_doc.Resolve(cidFont["CIDToGIDMap"]) is PdfStream stream)
            {
                try
                {
                    map = _doc.Data(stream, 1 << 17);
                }
                catch (PdfReadException)
                {
                }
            }
            if (map is null)
            {
                for (int gid = 1; gid < tt.GlyphCount; gid++)
                {
                    if (!tt.GlyphData(gid).IsEmpty) cids.Add(gid);
                }
            }
            else
            {
                for (int cid = 0; 2 * cid + 1 < map.Length; cid++)
                {
                    int gid = map[2 * cid] << 8 | map[2 * cid + 1];
                    if (gid > 0 && !tt.GlyphData(gid).IsEmpty) cids.Add(cid);
                }
            }
        }
        return cids;
    }

    private static IEnumerable<string> ProgramGlyphNames(FontProgram program) =>
        program.Type1 is { } type1 ? type1.GlyphNames.Take(MaxFontCodes)
        : program.Cff is { } cff ? Enumerable.Range(1, Math.Max(0, Math.Min(cff.GlyphCount, MaxFontCodes) - 1)).Select(g => cff.GlyphName(g) ?? ".notdef")
        : [];

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
