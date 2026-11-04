namespace LazyPDF.Core;

public sealed partial class PdfFont
{
    /// <summary>
    /// Whether the embedded program has an outline for the character. True for a font with no
    /// program of its own (the viewer draws it), and for white space, whose glyph is empty.
    /// </summary>
    internal bool CanDraw(in FontChar ch)
    {
        if (!IsEmbedded || Program is not { } program) return true;
        bool blank = ch.Unicode is { Length: > 0 } text && text.All(char.IsWhiteSpace);
        if (IsComposite)
        {
            if (program.TrueType is { Cff: null } tt)
            {
                int gid = GlyphOf(ch.Cid);
                return gid > 0 ? tt.GetBounds(gid) is not null || blank : blank;
            }
            if (program.Cff is { } cff)
            {
                int gid = cff.IsCid ? cff.GlyphForCid(ch.Cid) : ch.Cid;
                return gid > 0 ? cff.GetOutline(gid) is { IsEmpty: false } || blank : blank;
            }
            return true;
        }
        int code = ch.Code;
        if (program.TrueType is { Cff: null } simple)
        {
            int gid = TrueTypeGlyph(simple, code);
            return gid > 0 ? simple.GetBounds(gid) is not null || blank : blank;
        }
        string? name = Names[code];
        if (program.Type1 is { } t1) return name is not null && t1.HasGlyph(name);
        if (program.Cff is { } bare)
        {
            int gid = name is not null ? bare.GlyphForName(name) : 0;
            if (gid == 0) gid = bare.GlyphForCode(code);
            return gid > 0 ? bare.GetOutline(gid) is { IsEmpty: false } || blank : blank;
        }
        return true;
    }
}
