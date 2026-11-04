using System.Text;

namespace LazyPDF.Core;

// Subset sets and TrueType encodings of fonts that are already embedded.
internal sealed partial class PdfAConversionRun
{
    private const int MaxCharSet = 32767;

    private static bool IsSubsetName(string? name) =>
        name is { Length: > 7 } && name[6] == '+' && name.AsSpan(0, 6).IndexOfAnyExceptInRange('A', 'Z') < 0;

    // 6.3.5: part 1 wants a CIDSet or CharSet on a subset; a set that is there is rebuilt from the program when it misses a glyph the program
    // holds or the content shows, and dropped when it cannot be.
    private bool FixSubsetSets(PdfDictionary descriptor, PdfDictionary holder, PdfFont pdfFont, SortedSet<int> used)
    {
        bool wanted = Part == 1 && IsSubsetName(_doc.Name(descriptor, "FontName"));
        var program = FontProgram.Load(_doc, descriptor);
        bool changed = false;
        if (pdfFont.IsComposite)
        {
            var set = _doc.Stream(descriptor, "CIDSet");
            var cids = ProgramCids(program, holder, used);
            if (set is null ? wanted : !CidSetCovers(set, cids ?? used))
                changed |= Put(descriptor, "CIDSet", cids is null ? null : _doc.Add(CidSetStream(cids)));
        }
        else if (_doc.Name(holder, "Subtype") is "Type1" or "MMType1")
        {
            var listed = _doc.Resolve(descriptor["CharSet"]) is PdfString charSet ? CharSetNames(charSet) : null;
            var shown = used.Select(pdfFont.GlyphNameOf).OfType<string>().Where(g => g != ".notdef").ToHashSet();
            var names = ProgramNames(program, shown);
            if (listed is null ? wanted : !(names?.IsSubsetOf(listed) ?? shown.IsSubsetOf(listed))) changed |= Put(descriptor, "CharSet", CharSet(names));
        }
        return changed;
    }

    private static bool Put(PdfDictionary descriptor, string key, PdfObject? value)
    {
        if (value is null) return descriptor.Remove(key);
        descriptor[key] = value;
        return true;
    }

    private bool CidSetCovers(PdfStream set, IEnumerable<int> cids)
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

    private static HashSet<string> CharSetNames(PdfString charSet) =>
        Encoding.Latin1.GetString(charSet.Bytes).Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();

    // The CIDs of every glyph the program draws, the shown ones among them; null when the program or its /CIDToGIDMap cannot be read.
    private SortedSet<int>? ProgramCids(FontProgram? program, PdfDictionary holder, SortedSet<int> used)
    {
        byte[]? map = null;
        if (_doc.Resolve(holder["CIDToGIDMap"]) is PdfStream stream)
        {
            try
            {
                map = _doc.Data(stream, 1 << 17);
            }
            catch (PdfReadException)
            {
                return null;
            }
        }
        var cids = new SortedSet<int>(used) { 0 };
        return program is not null && AddGlyphCids(cids, program.Cff, program.TrueType, map) ? cids : null;
    }

    // An empty slot of a subset TrueType font is no glyph. With a map the CIDs are the entries that reach one.
    private static bool AddGlyphCids(SortedSet<int> cids, CffFont? cff, TrueTypeFont? tt, byte[]? map)
    {
        if (cff is not null)
        {
            for (int glyph = 0; glyph < cff.GlyphCount; glyph++) cids.Add(cff.CidForGlyph(glyph));
        }
        else if (tt is null)
        {
            return false;
        }
        else if (map is null)
        {
            for (int glyph = 0; glyph < tt.GlyphCount; glyph++)
            {
                if (tt.GlyphData(glyph).Length > 0) cids.Add(glyph);
            }
        }
        else
        {
            for (int cid = 0; 2 * cid + 1 < map.Length; cid++)
            {
                int glyph = map[2 * cid] << 8 | map[2 * cid + 1];
                if (glyph > 0 && tt.GlyphData(glyph).Length > 0) cids.Add(cid);
            }
        }
        return true;
    }

    private static PdfStream CidSetStream(IReadOnlyCollection<int> cids)
    {
        var bits = new byte[(cids.Max() >> 3) + 1];
        foreach (int cid in cids) bits[cid >> 3] |= (byte)(0x80 >> (cid & 7));
        var dictionary = new PdfDictionary();
        dictionary["Filter"] = new PdfName("FlateDecode");
        return new PdfStream(dictionary, PdfFilterEncoders.Flate(bits));
    }

    // Names of the glyphs the program holds and the content shows; null for a program that does not list names. ISO 32000-1 Table 122 leaves .notdef out.
    private static SortedSet<string>? ProgramNames(FontProgram? program, IEnumerable<string> shown)
    {
        var names = new SortedSet<string>(shown, StringComparer.Ordinal);
        if (program?.Type1 is { } type1) names.UnionWith(type1.GlyphNames);
        else if (program?.Cff is { } cff && !cff.IsCid) names.UnionWith(Enumerable.Range(0, cff.GlyphCount).Select(cff.GlyphName).OfType<string>());
        else return null;
        names.Remove(".notdef");
        return names;
    }

    private static PdfObject? CharSet(SortedSet<string>? names)
    {
        if (names is null) return null;
        string text = string.Concat(names.Where(n => n.All(c => c is > ' ' and < '\u007F' and not ('/' or '(' or ')'))).Select(n => "/" + n));
        return text.Length > MaxCharSet ? null : new PdfString(Encoding.Latin1.GetBytes(text), isHex: false);
    }

    // 9.6.6.4 and 6.2.11.6: a non-symbolic TrueType font names WinAnsi or MacRoman, and names of other glyphs go in /Differences, which
    // the standard allows only with AGL names and a (3,1) cmap. A code the content shows keeps its glyph; when that cannot be done within
    // the rules the font is left as it is and reported.
    private bool FixEncoding(PdfDictionary font, PdfDictionary holder, PdfDictionary descriptor, PdfFont pdfFont, SortedSet<int> used, string? subtype)
    {
        if (subtype == "Type0")
        {
            if (_doc.Name(holder, "Subtype") != "CIDFontType2" || !descriptor.ContainsKey("FontFile2") || holder["CIDToGIDMap"] is not null) return false;
            holder["CIDToGIDMap"] = new PdfName("Identity");
            return true;
        }
        if (subtype != "TrueType") return false;
        long flags = _doc.Integer(descriptor, "Flags") ?? 0;
        var encoding = _doc.Resolve(font["Encoding"]);
        var tt = FontProgram.Load(_doc, descriptor)?.TrueType is { Cff: null } parsed ? parsed : null;
        bool symbolic = (flags & 4) != 0 && (flags & 32) == 0;
        if (symbolic)
        {
            if (encoding is null) return false;
            if (SameGlyphsByCode(tt, pdfFont, used)) return font.Remove("Encoding");
        }

        string? baseName = encoding switch { PdfName n => n.Value, PdfDictionary e => _doc.Name(e, "BaseEncoding"), _ => null };
        bool named = baseName is "WinAnsiEncoding" or "MacRomanEncoding";
        var read = encoding is PdfDictionary dictionary ? ReadDifferences(_doc.Array(dictionary, "Differences")) : new SortedDictionary<int, string>();
        var listed = named ? read : new SortedDictionary<int, string>();
        bool unicodeCmap = tt is null || tt.HasCmap(3, 1);
        if (symbolic && !unicodeCmap) return false;
        var differences = new SortedDictionary<int, string>(unicodeCmap ? listed.Where(p => AglNames.Value.Contains(p.Value)).ToDictionary() : []);
        string table = named ? baseName! : "WinAnsiEncoding";
        var names = PdfEncodings.ByName(table)!;
        if (tt is not null)
        {
            foreach (int code in used)
            {
                // Without a base encoding a non-symbolic font starts from StandardEncoding (9.6.6.4), where PdfFont assumes WinAnsi.
                string? shown = baseName is null && !symbolic ? read.GetValueOrDefault(code) ?? PdfEncodings.Standard[code] : pdfFont.GlyphNameOf(code);
                int old = DrawnGlyph(tt, shown, code);
                if (old == 0 || old == DrawnGlyph(tt, differences.GetValueOrDefault(code) ?? names[code], code)) continue;
                if (!unicodeCmap || PinName(pdfFont, tt, old) is not { } pin) return LeftAsItIs(pdfFont, named && !symbolic);
                differences[code] = pin;
            }
        }
        bool same = named && differences.SequenceEqual(listed);
        if (symbolic) descriptor["Flags"] = new PdfNumber((flags & ~4L) | 32);
        if (same) return symbolic;
        font["Encoding"] = differences.Count == 0 ? new PdfName(table) : EncodingDictionary(table, differences);
        return true;
    }

    // A font with no named base is reported by the checker already; one with WinAnsi or MacRoman and /Differences that cannot go is reported here.
    private bool LeftAsItIs(PdfFont pdfFont, bool named)
    {
        if (named) _left.Add(new PdfAIssue(Part == 1 ? "6.3.7" : "6.2.11.6", PdfAText.FontName(pdfFont.BaseFont), PdfAText.TrueTypeDifferences));
        return false;
    }

    private static readonly Lazy<HashSet<string>> AglNames = new(() =>
        TableBlob.InflateText(GlyphListData.Agl).Split('\n').Select(line => line.Split(' ')).Where(parts => parts.Length > 1).Select(parts => parts[0]).ToHashSet());

    // The names of Apple's Mac OS Roman that 9.6.6.4 goes through and PDF's MacRomanEncoding leaves out.
    private static readonly Lazy<Dictionary<string, int>> MacCodes = new(() =>
    {
        var codes = CodesByName(PdfEncodings.MacRoman)!;
        string[] extra = ["notequal", "infinity", "lessequal", "greaterequal", "partialdiff", "summation", "product", "pi", "integral", "Omega", "radical", "approxequal", "Delta", "lozenge", "apple", "Euro"];
        int[] at = [0xAD, 0xB0, 0xB2, 0xB3, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBD, 0xC3, 0xC5, 0xC6, 0xD7, 0xF0, 0xDB];
        for (int i = 0; i < extra.Length; i++) codes.TryAdd(extra[i], at[i]);
        return codes;
    });

    // The glyph the reader draws for a code: the one the name reaches, else the code through the others.
    private static int DrawnGlyph(TrueTypeFont tt, string? name, int code) =>
        name is not null && ByName(tt, name) is > 0 and var glyph ? glyph : ByCode(tt, code);

    // 9.6.6.4: the character of the name through the (3,1) cmap, and without one the Mac OS Roman code of the name through the (1,0) cmap;
    // a name that reaches no glyph that way is looked up in the 'post' table.
    private static int ByName(TrueTypeFont tt, string name)
    {
        int glyph;
        if (!tt.HasCmap(3, 1) && tt.HasCmap(1, 0)) glyph = MacCodes.Value.TryGetValue(name, out int mac) ? tt.GlyphForCmap(1, 0, mac) : 0;
        else glyph = GlyphList.UnicodeOf(name) is { Length: > 0 } text ? tt.GlyphForCodePoint(char.ConvertToUtf32(text, 0)) : 0;
        return glyph > 0 ? glyph : tt.GlyphForName(name);
    }

    private static int ByCode(TrueTypeFont tt, int code)
    {
        int glyph = tt.GlyphForCmap(3, 0, code);
        if (glyph == 0) glyph = tt.GlyphForCmap(3, 0, 0xF000 + code);
        if (glyph == 0) glyph = tt.GlyphForCmap(1, 0, code);
        return glyph != 0 ? glyph : tt.GlyphForCodePoint(code);
    }

    // A name that reaches the glyph through the Unicode cmap, or null when the glyph has no character of its own there.
    private static string? PinName(PdfFont pdfFont, TrueTypeFont tt, int glyph)
    {
        if (pdfFont.Program?.UnicodeOf(glyph) is not { Length: > 0 } text || SingleCodePoint(text) is not { } codePoint) return null;
        string name = GlyphList.NameOf(codePoint);
        return tt.GlyphForCodePoint(codePoint) == glyph && AglNames.Value.Contains(name) ? name : null;
    }

    // The reader finds a glyph by the name first (9.6.6.4); without an encoding the cmap by code decides, and it has to agree.
    private static bool SameGlyphsByCode(TrueTypeFont? tt, PdfFont pdfFont, SortedSet<int> used)
    {
        if (tt is null) return true;
        foreach (int code in used)
        {
            if (pdfFont.GlyphNameOf(code) is not { } name) continue;
            int byName = ByName(tt, name);
            if (byName > 0 && byName != ByCode(tt, code)) return false;
        }
        return true;
    }

    private SortedDictionary<int, string> ReadDifferences(PdfArray? array)
    {
        var result = new SortedDictionary<int, string>();
        int code = 0;
        if (array is null) return result;
        foreach (var item in array.Items)
        {
            switch (_doc.Resolve(item))
            {
                case PdfNumber number:
                    code = (int)Math.Clamp(number.Value, 0, 256);
                    break;
                case PdfName glyph:
                    if (code < 256) result[code] = glyph.Value;
                    code++;
                    break;
            }
        }
        return result;
    }

    private static PdfDictionary EncodingDictionary(string baseName, SortedDictionary<int, string> differences)
    {
        var items = new List<PdfObject>();
        int next = -1;
        foreach (var (code, glyph) in differences)
        {
            if (code != next) items.Add(new PdfNumber(code));
            items.Add(new PdfName(glyph));
            next = code + 1;
        }
        var dictionary = new PdfDictionary();
        dictionary["Type"] = new PdfName("Encoding");
        dictionary["BaseEncoding"] = new PdfName(baseName);
        dictionary["Differences"] = new PdfArray(items);
        return dictionary;
    }
}
