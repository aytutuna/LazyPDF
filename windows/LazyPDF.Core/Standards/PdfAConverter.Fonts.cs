using System.Text;

namespace LazyPDF.Core;

// Fonts: a font that is not embedded is replaced in place by an embedded subset, keeping the codes the content uses,
// and the faults of an embedded one (widths, subset sets, encodings, a missing /ToUnicode) are corrected.
internal sealed partial class PdfAConversionRun
{
    private void FixFonts(PdfAChecker before)
    {
        int embedded = 0, corrected = 0;
        foreach (var font in before.Fonts.ToList())
        {
            var pdfFont = PdfFont.Get(_doc, font);
            string? subtype = _doc.Name(font, "Subtype");
            before.FontUses.TryGetValue(font, out var used);
            used ??= [];
            if (subtype == "Type3")
            {
                if (before.NeedsToUnicode(pdfFont) && AddToUnicode(font, pdfFont, used)) corrected++;
                continue;
            }
            var holder = subtype == "Type0" && _doc.Array(font, "DescendantFonts") is { Items.Count: > 0 } kids && _doc.Resolve(kids.Items[0]) is PdfDictionary d ? d : font;
            var descriptor = _doc.Dict(holder, "FontDescriptor");
            bool isEmbedded = descriptor is not null && (descriptor.ContainsKey("FontFile") || descriptor.ContainsKey("FontFile2") || descriptor.ContainsKey("FontFile3"));
            if (!isEmbedded)
            {
                if (subtype == "Type0" ? EmbedComposite(font, holder, pdfFont, used) : EmbedSimple(font, pdfFont, used)) embedded++;
                continue;
            }
            bool changed = FixWidths(font, holder, pdfFont, used);
            changed |= FixSubsetSets(descriptor!, pdfFont, used);
            changed |= FixEncoding(font, holder, descriptor!, subtype);
            if (before.NeedsToUnicode(pdfFont)) changed |= AddToUnicode(font, pdfFont, used);
            if (changed) corrected++;
        }
        if (embedded > 0) Changed(PdfAText.FontsEmbedded(embedded));
        if (corrected > 0) Changed(PdfAText.FontsCorrected(corrected));
    }

    private static (string Family, FontStyles Style, bool Symbolic) Choose(PdfFont font)
    {
        var std = Standard14.Find(font.Name);
        var style = (font.IsBold ? FontStyles.Bold : 0) | (font.IsItalic ? FontStyles.Italic : 0);
        if (std is not null)
        {
            style = (std.IsBold ? FontStyles.Bold : 0) | (std.IsItalic ? FontStyles.Italic : 0);
            string family = std.Name switch
            {
                var n when n.StartsWith("Helvetica", StringComparison.Ordinal) => "Arial",
                var n when n.StartsWith("Times", StringComparison.Ordinal) => "Times New Roman",
                var n when n.StartsWith("Courier", StringComparison.Ordinal) => "Courier New",
                var n => n,
            };
            return (family, style, std.IsSymbolic);
        }
        string name = font.Name.Split('-', ',')[0].Replace("PS", "", StringComparison.Ordinal).Replace("MT", "", StringComparison.Ordinal);
        return (name.Length > 0 ? name : Generic(font), style, false);
    }

    private static string Generic(PdfFont font) => font.IsFixedPitch ? "Courier New" : font.IsSerif ? "Times New Roman" : "Arial";

    private FontFile? FindFile(PdfFont font, string family, FontStyles style) =>
        fonts?.Find(family, style) ?? fonts?.Find(Generic(font), style);

    private static string FirstCharacter(string text) => char.ConvertFromUtf32(char.ConvertToUtf32(text, 0));

    private bool EmbedSimple(PdfDictionary font, PdfFont pdfFont, SortedSet<int> used)
    {
        var (family, style, symbolic) = Choose(pdfFont);
        if (FindFile(pdfFont, family, style) is not { } file) return false;
        var unicode = new SortedDictionary<int, string>();
        for (int code = 0; code < 256; code++)
        {
            if (code < 32 && !used.Contains(code)) continue;
            pdfFont.Read([(byte)code], out var character);
            if (character.Unicode is { Length: > 0 } text) unicode[code] = text;
        }
        // A symbol font's glyphs sit at 0xF000 and up in its (3,0) cmap, whatever they stand for.
        var lookup = unicode.ToDictionary(p => p.Key, p => symbolic ? char.ConvertFromUtf32(0xF000 + p.Key) : FirstCharacter(p.Value));
        if (lookup.Count == 0 || EmbeddedFontBuilder.Build(file.Data, [string.Concat(lookup.Values)], out _, file.CollectionIndex) is not { } built) return false;

        var cidOf = new SortedDictionary<int, int>();
        foreach (var (code, key) in lookup)
        {
            if (built.Codes.TryGetValue(char.ConvertToUtf32(key, 0), out int cid)) cidOf[code] = cid;
        }
        var map = new CMapEntries(cidOf);
        var cidFont = BuildCidFont(built, pdfFont.Name);
        var type0 = new PdfDictionary();
        type0["Type"] = new PdfName("Font");
        type0["Subtype"] = new PdfName("Type0");
        type0["BaseFont"] = new PdfName(built.BaseFont);
        type0["Encoding"] = _doc.Add(map.ToStream());
        type0["DescendantFonts"] = new PdfArray([_doc.Add(cidFont)]);
        type0["ToUnicode"] = _doc.Add(ToUnicodeStream(unicode, 1));
        Replace(font, type0);
        return true;
    }

    private bool EmbedComposite(PdfDictionary font, PdfDictionary cid, PdfFont pdfFont, SortedSet<int> used)
    {
        if (_doc.Resolve(font["Encoding"]) is not PdfName { Value: "Identity-H" or "Identity-V" } || _doc.Name(cid, "Subtype") != "CIDFontType2") return false;
        var (family, style, _) = Choose(pdfFont);
        if (FindFile(pdfFont, family, style) is not { } file) return false;
        var unicode = new SortedDictionary<int, string>();
        foreach (int value in used)
        {
            pdfFont.Read([(byte)(value >> 8), (byte)value], out var character);
            if (character.Unicode is { Length: > 0 } text) unicode[value] = text;
        }
        if (unicode.Count == 0 || EmbeddedFontBuilder.Build(file.Data, [string.Concat(unicode.Values.Select(FirstCharacter))], out _, file.CollectionIndex) is not { IsCff: false } built) return false;

        var gid = new byte[(unicode.Keys.Max() + 1) * 2];
        var widthOf = built.Widths.SelectMany(r => r.Widths.Select((w, i) => (Cid: r.FirstCid + i, Width: w))).ToDictionary(p => p.Cid, p => p.Width);
        var widths = new SortedDictionary<int, double>();
        foreach (var (value, text) in unicode)
        {
            if (!built.Codes.TryGetValue(char.ConvertToUtf32(text, 0), out int code)) continue;
            gid[2 * value] = (byte)(code >> 8);
            gid[2 * value + 1] = (byte)code;
            widths[value] = widthOf.GetValueOrDefault(code);
        }
        var fresh = BuildCidFont(built, pdfFont.Name);
        cid["BaseFont"] = new PdfName(built.BaseFont);
        cid["FontDescriptor"] = fresh["FontDescriptor"]!;
        var toGid = new PdfDictionary();
        toGid["Filter"] = new PdfName("FlateDecode");
        cid["CIDToGIDMap"] = _doc.Add(new PdfStream(toGid, PdfFilterEncoders.Flate(gid)));
        cid["W"] = WidthArray(widths);
        font["BaseFont"] = new PdfName(built.BaseFont);
        if (!pdfFont.HasToUnicode) font["ToUnicode"] = _doc.Add(ToUnicodeStream(unicode, 2));
        return true;
    }

    private PdfDictionary BuildCidFont(EmbeddedFont built, string name)
    {
        var fontFile = new PdfDictionary();
        fontFile["Length1"] = new PdfNumber(built.Program.Length);
        if (built.IsCff) fontFile["Subtype"] = new PdfName("OpenType");
        fontFile["Filter"] = new PdfName("FlateDecode");
        var file = _doc.Add(new PdfStream(fontFile, PdfFilterEncoders.Flate(built.Program)));

        var d = built.Descriptor;
        var descriptor = new PdfDictionary();
        descriptor["Type"] = new PdfName("FontDescriptor");
        descriptor["FontName"] = new PdfName(built.BaseFont);
        descriptor["Flags"] = new PdfNumber(d.Flags);
        descriptor["FontBBox"] = new PdfArray([.. d.FontBBox.Select(n => (PdfObject)new PdfNumber(n))]);
        descriptor["ItalicAngle"] = new PdfNumber(d.ItalicAngle);
        descriptor["Ascent"] = new PdfNumber(d.Ascent);
        descriptor["Descent"] = new PdfNumber(d.Descent);
        descriptor["CapHeight"] = new PdfNumber(d.CapHeight);
        descriptor["StemV"] = new PdfNumber(d.StemV);
        descriptor[built.IsCff ? "FontFile3" : "FontFile2"] = file;

        var widths = new List<PdfObject>();
        foreach (var run in built.Widths)
        {
            widths.Add(new PdfNumber(run.FirstCid));
            widths.Add(new PdfArray([.. run.Widths.Select(w => (PdfObject)new PdfNumber(w))]));
        }
        var info = new PdfDictionary();
        info["Registry"] = new PdfString("Adobe"u8.ToArray(), isHex: false);
        info["Ordering"] = new PdfString("Identity"u8.ToArray(), isHex: false);
        info["Supplement"] = new PdfNumber(0L);
        var cid = new PdfDictionary();
        cid["Type"] = new PdfName("Font");
        cid["Subtype"] = new PdfName(built.IsCff ? "CIDFontType0" : "CIDFontType2");
        cid["BaseFont"] = new PdfName(built.BaseFont);
        cid["CIDSystemInfo"] = info;
        cid["FontDescriptor"] = _doc.Add(descriptor);
        cid["DW"] = new PdfNumber(built.DefaultWidth);
        cid["W"] = new PdfArray(widths);
        if (!built.IsCff) cid["CIDToGIDMap"] = new PdfName("Identity");
        return cid;
    }

    /// <summary>Puts the keys of <paramref name="source"/> in <paramref name="target"/> and takes the others out, so references to the font stay good.</summary>
    private static void Replace(PdfDictionary target, PdfDictionary source)
    {
        foreach (var (key, _) in target.Entries.ToList()) target.Remove(key);
        foreach (var (key, value) in source.Entries) target[key] = value;
    }

    private PdfStream ToUnicodeStream(SortedDictionary<int, string> map, int codeBytes)
    {
        var dictionary = new PdfDictionary();
        dictionary["Filter"] = new PdfName("FlateDecode");
        var entries = map.Where(p => p.Value.Length > 0).Select(p => new KeyValuePair<int, string>(p.Key, p.Value));
        return new PdfStream(dictionary, PdfFilterEncoders.Flate(ToUnicodeCMap.Write(entries, codeBytes)));
    }

    private static PdfArray WidthArray(SortedDictionary<int, double> widths)
    {
        var items = new List<PdfObject>();
        List<PdfObject>? run = null;
        int next = -1;
        foreach (var (cid, width) in widths)
        {
            if (run is null || cid != next)
            {
                run = [];
                items.Add(new PdfNumber(cid));
                items.Add(new PdfArray(run));
            }
            run.Add(new PdfNumber(Math.Round(width, 3)));
            next = cid + 1;
        }
        return new PdfArray(items);
    }

    // Widths the content shows are set to what the font program has, as the standard wants them to agree.
    private bool FixWidths(PdfDictionary font, PdfDictionary holder, PdfFont pdfFont, SortedSet<int> used)
    {
        if (pdfFont.IsType3) return false;
        var fixes = new SortedDictionary<int, double>();
        foreach (int key in used)
        {
            double? program = pdfFont.IsComposite ? pdfFont.ProgramCidWidth(key) : pdfFont.ProgramWidth(key);
            double declared = pdfFont.IsComposite ? pdfFont.CidWidths.GetValueOrDefault(key, _doc.Number(holder, "DW") ?? 1000) : ReadWidth(pdfFont, key);
            if (program is { } own && Math.Abs(own - declared) > 1) fixes[key] = Math.Round(own, 3);
        }
        bool missing = !pdfFont.IsComposite && (!font.ContainsKey("Widths") || !font.ContainsKey("FirstChar"));
        if (fixes.Count == 0 && !missing) return false;
        if (pdfFont.IsComposite)
        {
            var all = new SortedDictionary<int, double>(pdfFont.CidWidths.ToDictionary(p => p.Key, p => p.Value));
            foreach (var (cid, width) in fixes) all[cid] = width;
            holder["W"] = WidthArray(all);
            return true;
        }
        int first = Math.Min(missing ? 32 : (int)Math.Clamp(_doc.Integer(font, "FirstChar") ?? 0, 0, 255), fixes.Count > 0 ? fixes.Keys.Min() : 255);
        int last = Math.Max(missing ? 255 : (int)Math.Clamp(_doc.Integer(font, "LastChar") ?? 255, 0, 255), fixes.Count > 0 ? fixes.Keys.Max() : 0);
        var widths = new List<PdfObject>();
        for (int code = first; code <= last; code++)
        {
            double width = fixes.TryGetValue(code, out double fixedWidth) ? fixedWidth : ReadWidth(pdfFont, code);
            if (missing && !fixes.ContainsKey(code) && pdfFont.ProgramWidth(code) is { } own) width = own;
            widths.Add(new PdfNumber(Math.Round(width, 3)));
        }
        font["FirstChar"] = new PdfNumber(first);
        font["LastChar"] = new PdfNumber(last);
        font["Widths"] = new PdfArray(widths);
        return true;
    }

    private static double ReadWidth(PdfFont font, int code)
    {
        font.Read([(byte)code], out var character);
        return character.Width;
    }

    private bool FixSubsetSets(PdfDictionary descriptor, PdfFont pdfFont, SortedSet<int> used)
    {
        bool changed = false;
        if (_doc.Stream(descriptor, "CIDSet") is { } set)
        {
            byte[]? bits = null;
            try
            {
                bits = _doc.Data(set, 1 << 20);
            }
            catch (PdfReadException)
            {
            }
            if (bits is null || used.Any(cid => (cid >> 3) >= bits.Length || (bits[cid >> 3] & (0x80 >> (cid & 7))) == 0))
            {
                descriptor.Remove("CIDSet");
                changed = true;
            }
        }
        if (_doc.Resolve(descriptor["CharSet"]) is PdfString charSet)
        {
            var listed = Encoding.Latin1.GetString(charSet.Bytes).Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();
            if (used.Select(pdfFont.GlyphNameOf).Any(g => g is not (null or ".notdef") && !listed.Contains(g)))
            {
                descriptor.Remove("CharSet");
                changed = true;
            }
        }
        return changed;
    }

    private bool FixEncoding(PdfDictionary font, PdfDictionary holder, PdfDictionary descriptor, string? subtype)
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
        if ((flags & 4) != 0 && (flags & 32) == 0)
        {
            return encoding is not null && font.Remove("Encoding");
        }
        string? baseName = encoding switch { PdfName n => n.Value, PdfDictionary e => _doc.Name(e, "BaseEncoding"), _ => null };
        if (baseName is "WinAnsiEncoding" or "MacRomanEncoding") return false;
        if (encoding is PdfDictionary dictionary) dictionary["BaseEncoding"] = new PdfName("WinAnsiEncoding");
        else font["Encoding"] = new PdfName("WinAnsiEncoding");
        return true;
    }

    // Level U: the codes the font shows get text from what the reader can trace; a code mapped to nothing is left out.
    private bool AddToUnicode(PdfDictionary font, PdfFont pdfFont, SortedSet<int> used)
    {
        var map = new SortedDictionary<int, string>();
        int bytes = pdfFont.IsComposite ? 2 : 1;
        if (pdfFont.IsComposite && _doc.Resolve(font["Encoding"]) is not PdfName { Value: "Identity-H" or "Identity-V" }) return false;
        foreach (int key in pdfFont.IsComposite ? used : Enumerable.Range(0, 256))
        {
            pdfFont.Read(bytes == 2 ? [(byte)(key >> 8), (byte)key] : [(byte)key], out var character);
            if (character.Unicode is { Length: > 0 } text) map[key] = text;
        }
        if (map.Count == 0) return false;
        font["ToUnicode"] = _doc.Add(ToUnicodeStream(map, bytes));
        return true;
    }

    /// <summary>An embedded one-byte CMap sending each code to a CID: <c>cidchar</c> entries, 100 to a section.</summary>
    private sealed class CMapEntries(SortedDictionary<int, int> cids)
    {
        public PdfStream ToStream()
        {
            var sb = new StringBuilder();
            sb.Append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n");
            sb.Append("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n");
            sb.Append("/CMapName /LazyPDF-Byte def\n/CMapType 1 def\n");
            sb.Append("1 begincodespacerange\n<00> <FF>\nendcodespacerange\n");
            foreach (var section in cids.Chunk(100))
            {
                sb.Append(section.Length).Append(" begincidchar\n");
                foreach (var (code, cid) in section) sb.Append('<').Append(code.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)).Append("> ").Append(cid).Append('\n');
                sb.Append("endcidchar\n");
            }
            sb.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");

            var dictionary = new PdfDictionary();
            dictionary["Type"] = new PdfName("CMap");
            dictionary["CMapName"] = new PdfName("LazyPDF-Byte");
            var info = new PdfDictionary();
            info["Registry"] = new PdfString("Adobe"u8.ToArray(), isHex: false);
            info["Ordering"] = new PdfString("Identity"u8.ToArray(), isHex: false);
            info["Supplement"] = new PdfNumber(0L);
            dictionary["CIDSystemInfo"] = info;
            dictionary["Filter"] = new PdfName("FlateDecode");
            return new PdfStream(dictionary, PdfFilterEncoders.Flate(Encoding.ASCII.GetBytes(sb.ToString())));
        }
    }
}
