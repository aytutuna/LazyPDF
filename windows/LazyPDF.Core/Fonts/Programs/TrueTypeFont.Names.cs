using System.Text;
using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

public sealed partial class TrueTypeFont
{
    private string?[]? _glyphNames;
    private Dictionary<string, int>? _nameToGlyph;

    /// <summary>Glyph name from 'post' (formats 1 and 2) or the CFF charset, null when the font has none for it.</summary>
    public string? GlyphName(int glyphId)
    {
        _glyphNames ??= ReadGlyphNames();
        return glyphId >= 0 && glyphId < _glyphNames.Length ? _glyphNames[glyphId] : null;
    }

    /// <summary>The first glyph with this name, 0 when there is none.</summary>
    public int GlyphForName(string name)
    {
        if (_nameToGlyph == null)
        {
            _glyphNames ??= ReadGlyphNames();
            var map = new Dictionary<string, int>(_glyphNames.Length);
            for (var g = 0; g < _glyphNames.Length; g++)
                if (_glyphNames[g] is { } n) map.TryAdd(n, g);
            _nameToGlyph = map;
        }
        return _nameToGlyph.GetValueOrDefault(name);
    }

    private string?[] ReadGlyphNames()
    {
        var post = Table("post");
        var format = U32(post, 0);
        var names = new string?[GlyphCount];

        if (format == 0x00010000)
        {
            for (var g = 0; g < names.Length && g < StandardNames.MacGlyphs.Length; g++)
                names[g] = StandardNames.MacGlyphs[g];
            return names;
        }

        if (format == 0x00020000)
        {
            var n = Math.Min(U16(post, 32), (post.Length - 34) / 2);
            var custom = new List<string>();
            for (var p = 34 + 2 * n; p < post.Length;)
            {
                var len = post[p];
                if (p + 1 + len > post.Length) break;
                custom.Add(Encoding.Latin1.GetString(post.Slice(p + 1, len)));
                p += 1 + len;
            }
            for (var g = 0; g < n && g < names.Length; g++)
            {
                var idx = U16(post, 34 + 2 * g);
                if (idx < StandardNames.MacGlyphs.Length) names[g] = StandardNames.MacGlyphs[idx];
                else if (idx - 258 < custom.Count) names[g] = custom[idx - 258];
            }
            return names;
        }

        if (Cff is { } cff)
            for (var g = 0; g < names.Length; g++)
                names[g] = cff.GlyphName(g);
        return names;
    }
}
