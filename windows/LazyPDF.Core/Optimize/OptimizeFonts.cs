using System.IO.Compression;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

// Trims fully embedded TrueType programs to the glyphs the document shows. A program is trimmed
// only when every font that uses it is listed in page, form or pattern resources and nowhere else
// (the form's /DR, a field's /DA, anything later editing could use), and every table that lists it
// was walked to the end. A program shared with a subset-tagged font is left alone.
internal sealed class OptimizeFonts(PdfDocument document)
{
    private static readonly Regex SubsetTag = new("^[A-Z]{6}\\+", RegexOptions.Compiled);

    private sealed class Program
    {
        public readonly List<PdfDictionary> Fonts = [];
        public bool Blocked, Tagged;
    }

    private sealed class Uses : OptimizeWalk
    {
        public readonly Dictionary<PdfDictionary, HashSet<int>> Codes = new(ReferenceEqualityComparer.Instance);

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (!Codes.TryGetValue(glyph.Font.Dictionary, out var set)) Codes[glyph.Font.Dictionary] = set = [];
            set.Add(glyph.Font.IsComposite ? glyph.Character.Cid : glyph.Character.Code);
        }
    }

    public int Run(out bool partial)
    {
        partial = false;
        var listed = ListedFonts(out var outside);
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var fonts = new List<(PdfDictionary Font, int Number, PdfStream Program)>();
        void Consider(PdfDictionary font, int number)
        {
            if (document.Name(font, "Subtype") is not ("TrueType" or "Type0") || !seen.Add(font) || ProgramOf(font) is not { } program) return;
            fonts.Add((font, number, program));
        }
        var numbers = new Dictionary<PdfDictionary, int>(ReferenceEqualityComparer.Instance);
        foreach (var (number, value) in PdfGraph.Objects(document))
        {
            if (value is PdfDictionary indirect) numbers[indirect] = number;
        }
        // A font written directly has no number to be referred to by, and is blocked unless a /Font table lists it.
        foreach (var font in PdfGraph.AllDictionaries(document)) Consider(font, numbers.GetValueOrDefault(font));
        if (fonts.Count == 0) return 0;

        var uses = new Uses();
        uses.Walk(document);
        var programs = new Dictionary<PdfStream, Program>(ReferenceEqualityComparer.Instance);
        foreach (var (font, number, stream) in fonts)
        {
            if (!programs.TryGetValue(stream, out var entry)) programs[stream] = entry = new Program();
            entry.Fonts.Add(font);
            if (SubsetTag.IsMatch(document.Name(font, "BaseFont") ?? "")) entry.Tagged = true;
            if (!uses.Complete || outside.Contains(number) || !listed.TryGetValue(font, out var owners) || !owners.All(uses.Reached)) entry.Blocked = true;
        }

        int trimmed = 0;
        foreach (var (stream, program) in programs)
        {
            if (program.Tagged) continue;
            if (program.Blocked) partial = true;
            else if (Trim(stream, program, uses)) trimmed++;
        }
        return trimmed;
    }

    // The font dictionaries named by a /Resources /Font dictionary with the resource dictionaries that hold it, and the numbers of objects referred to from anywhere else.
    private Dictionary<PdfDictionary, List<PdfDictionary>> ListedFonts(out HashSet<int> outside)
    {
        var tables = new Dictionary<PdfDictionary, List<PdfDictionary>>(ReferenceEqualityComparer.Instance);
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (document.Dict(dictionary, "Resources") is not { } resources || document.Dict(resources, "Font") is not { } fonts) continue;
            if (!tables.TryGetValue(fonts, out var owners)) tables[fonts] = owners = [];
            owners.Add(resources);
        }
        var listed = new Dictionary<PdfDictionary, List<PdfDictionary>>(ReferenceEqualityComparer.Instance);
        void List(PdfDictionary font, List<PdfDictionary> owners)
        {
            if (!listed.TryGetValue(font, out var all)) listed[font] = all = [];
            all.AddRange(owners);
        }
        outside = [];
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            foreach (var container in PdfGraph.ContainersOf(value))
            {
                var children = container is PdfDictionary d ? d.Entries.Select(e => e.Value) : ((PdfArray)container).Items;
                var owners = container is PdfDictionary table ? tables.GetValueOrDefault(table) : null;
                foreach (var child in children)
                {
                    if (child is not PdfReference reference) continue;
                    if (owners is not null && document.Get(reference.Number) is PdfDictionary font) List(font, owners);
                    else outside.Add(reference.Number);
                }
            }
        }
        foreach (var (table, owners) in tables)
        {
            foreach (var (_, item) in table.Entries)
            {
                if (item is PdfDictionary direct) List(direct, owners);
            }
        }
        return listed;
    }

    private PdfStream? ProgramOf(PdfDictionary font)
    {
        var holder = font;
        if (document.Name(font, "Subtype") == "Type0")
        {
            holder = document.Resolve(document.Array(font, "DescendantFonts")?.Items.FirstOrDefault()) as PdfDictionary;
            if (document.Name(holder, "Subtype") != "CIDFontType2") return null;
        }
        return document.Stream(document.Dict(holder, "FontDescriptor"), "FontFile2");
    }

    private bool Trim(PdfStream stream, Program program, Uses uses)
    {
        byte[] data;
        try
        {
            data = document.Data(stream);
        }
        catch (PdfReadException)
        {
            return false;
        }
        if (data.Length < 12 || data[0] == 't' && data[1] == 't' && data[2] == 'c') return false;
        var font = TrueTypeFont.TryParse(data);
        if (font is null || font.IsCff || !font.HasTable("glyf") || !font.SubsettingAllowed || !font.EmbeddingAllowed) return false;
        var glyphs = new HashSet<int>();
        foreach (var dictionary in program.Fonts)
        {
            uses.Codes.TryGetValue(dictionary, out var codes);
            if (document.Name(dictionary, "Subtype") == "Type0") Composite(dictionary, codes ?? [], glyphs);
            else Simple(dictionary, font, codes ?? [], glyphs);
        }
        var trimmed = TrueTypeTrim.Trim(data, glyphs);
        if (trimmed is null || trimmed.Length > data.Length * 0.9) return false;
        byte[] packed = PdfFilterEncoders.Flate(trimmed, CompressionLevel.SmallestSize);
        if (packed.Length >= document.RawData(stream).Length) return false;
        stream.Data = packed;
        stream.Dictionary["Filter"] = new PdfName("FlateDecode");
        stream.Dictionary.Remove("DecodeParms");
        stream.Dictionary["Length1"] = new PdfNumber(trimmed.Length);
        return true;
    }

    private void Composite(PdfDictionary font, HashSet<int> cids, HashSet<int> glyphs)
    {
        var descendant = (PdfDictionary)document.Resolve(document.Array(font, "DescendantFonts")!.Items[0])!;
        byte[]? map = document.Resolve(descendant["CIDToGIDMap"]) is PdfStream s ? SafeData(s) : null;
        foreach (int cid in cids)
        {
            if (map is null) glyphs.Add(cid);
            else if (2 * cid + 1 < map.Length) glyphs.Add(map[2 * cid] << 8 | map[2 * cid + 1]);
        }
    }

    private byte[]? SafeData(PdfStream stream)
    {
        try
        {
            return document.Data(stream);
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // Every glyph any reading of the encoding could pick for a code: more than needed, never fewer.
    private void Simple(PdfDictionary font, TrueTypeFont tt, HashSet<int> codes, HashSet<int> glyphs)
    {
        var differences = new Dictionary<int, string>();
        var encoding = document.Resolve(font["Encoding"]);
        if (encoding is PdfDictionary e && document.Array(e, "Differences") is { } list)
        {
            int at = 0;
            foreach (var item in list.Items.Take(4096))
            {
                if (document.Resolve(item) is PdfNumber n) at = (int)n.Value;
                else if (document.Resolve(item) is PdfName name) differences[at++] = name.Value;
            }
        }
        foreach (int code in codes)
        {
            var names = new List<string>();
            if (differences.TryGetValue(code, out string? named)) names.Add(named);
            foreach (var table in new[] { PdfEncodings.WinAnsi, PdfEncodings.MacRoman, PdfEncodings.Standard })
            {
                if (code is >= 0 and < 256 && table[code] is { } glyphName) names.Add(glyphName);
            }
            var found = new List<int>
            {
                tt.GlyphForCmap(3, 0, code), tt.GlyphForCmap(3, 0, 0xF000 + code), tt.GlyphForCmap(3, 0, 0xF100 + code),
                tt.GlyphForCmap(3, 0, 0xF200 + code), tt.GlyphForCmap(1, 0, code), tt.GlyphForCodePoint(code),
            };
            foreach (string name in names)
            {
                found.Add(tt.GlyphForName(name));
                int mac = PdfEncodings.CodeOf(PdfEncodings.MacRoman, name);
                if (mac >= 0) found.Add(tt.GlyphForCmap(1, 0, mac));
                if (GlyphList.UnicodeOf(name) is { Length: > 0 } text) found.Add(tt.GlyphForCodePoint(char.ConvertToUtf32(text, 0)));
            }
            foreach (int g in found)
            {
                if (g > 0) glyphs.Add(g);
            }
        }
    }
}
