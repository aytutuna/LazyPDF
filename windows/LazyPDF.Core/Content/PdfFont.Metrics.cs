namespace LazyPDF.Core;

// What the embedded font program itself says, for checks that set it against the dictionary.
public sealed partial class PdfFont
{
    /// <summary>The glyph name the encoding gives a code of a simple font.</summary>
    internal string? GlyphNameOf(int code) => IsComposite || (uint)code > 255 ? null : Names[code];

    /// <summary>The widths /W gives, by CID, of a composite font.</summary>
    internal IReadOnlyDictionary<int, double> CidWidths => _cidWidths;

    /// <summary>The advance in 1/1000 em the font program gives a code of a simple font; null without a program or the glyph.</summary>
    internal double? ProgramWidth(int code)
    {
        if (IsComposite || (uint)code > 255 || Program is not { } program) return null;
        if (program.Width(code, Names[code]) is { } own) return own;
        return program.TrueType is { Cff: null } tt && TrueTypeGlyph(tt, code) is > 0 and var gid ? tt.GetAdvance(gid) * 1000.0 / tt.UnitsPerEm : null;
    }

    /// <summary>The advance in 1/1000 em the font program gives a CID of a composite font; null without a program or the glyph.</summary>
    internal double? ProgramCidWidth(int cid)
    {
        if (!IsComposite || Program is not { } program) return null;
        if (program.TrueType is { Cff: null } tt)
        {
            int gid = GlyphOf(cid);
            return gid >= 0 && gid < tt.GlyphCount ? tt.GetAdvance(gid) * 1000.0 / tt.UnitsPerEm : null;
        }
        if (program.Cff is { } cff)
        {
            int gid = cff.IsCid ? cff.GlyphForCid(cid) : cid;
            return gid > 0 || cid == 0 ? cff.GetWidth(Math.Max(gid, 0)) * cff.FontMatrix[0] * 1000 : null;
        }
        return null;
    }
}
