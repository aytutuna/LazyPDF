using System.Text;

namespace LazyPDF.Core;

/// <summary>A font that stood in for the one in the file because that one had no glyph for some characters.</summary>
/// <param name="Original">The base font name of the font in the file.</param>
/// <param name="Replacement">The family the stand-in was asked for.</param>
/// <param name="Characters">The characters it draws.</param>
/// <param name="Embedded">The stand-in is embedded in the file; otherwise it is a Standard 14 font.</param>
public sealed record FontSubstitution(string Original, string Replacement, string Characters, bool Embedded);

/// <summary>One character of new text, ready for a show operator.</summary>
internal sealed class EditPiece
{
    public string Text { get; init; } = "";
    public byte[] Bytes { get; init; } = [];

    /// <summary>How far it moves the text position, in text space units (character and word spacing and horizontal scaling in).</summary>
    public double Advance { get; init; }

    /// <summary>The resource name of the stand-in font; null for the font in force.</summary>
    public string? Font { get; init; }

    /// <summary>The stand-in font the bytes were made in; its pieces are shaped together when the line is written.</summary>
    public PdfDrawFont? Draw { get; init; }

    public bool IsSpace { get; init; }

    /// <summary>The piece is a whole shaped run (see <see cref="TextBuilder.Shape"/>): <see cref="Text"/> is its logical text and <see cref="Bytes"/> is not used.</summary>
    public bool IsShaped { get; init; }

    /// <summary>The width in em before spacing and scaling, and whether word spacing applies to it (a single byte code 32).</summary>
    public double Em { get; init; }
    public bool Code32 { get; init; }

    /// <summary>A space the font has no glyph for is a move instead, in thousandths of the size.</summary>
    public double? Shift { get; init; }
}

/// <summary>Turns new text into pieces in the font of the text it replaces, or a stand-in where that font lacks the glyphs.</summary>
internal sealed class TextBuilder(PdfDocument document, EditBatch batch, IFontSource? fonts)
{
    private readonly Dictionary<PdfFont, FontCodec> _codecs = [];
    private readonly Dictionary<(ContentUnit, PdfFont), (PdfDrawFont Draw, string Name, string Covered)> _stand = [];

    private readonly List<(FontSubstitution Info, Place Place, string Name)> _made = [];

    /// <summary>The stand-ins whose font is still in the batch; one taken back with its edit is not reported.</summary>
    public IReadOnlyList<FontSubstitution> Substitutions => [.. _made.Where(m => batch.HasResource(m.Place, m.Name)).Select(m => m.Info)];

    public FontCodec Codec(PdfFont font)
    {
        if (!_codecs.TryGetValue(font, out var codec)) _codecs[font] = codec = new FontCodec(document, font);
        return codec;
    }

    public void WriteAdditions()
    {
        foreach (var codec in _codecs.Values) codec.WriteAdditions();
    }

    /// <summary>Whether every character of <paramref name="text"/> can be shown in <paramref name="font"/> as it is.</summary>
    public bool CanShow(PdfFont font, string text) => Runes(text).All(r => r == " " || Codec(font).TryGet(r, out _));

    private static List<string> Runes(string text) =>
        [.. text.EnumerateRunes().Where(r => r.Value >= 0x20 || r.Value == '\t').Select(r => r.Value == '\t' ? " " : r.ToString())];

    /// <summary>The pieces of <paramref name="text"/> in the font of <paramref name="anchor"/>; throws <see cref="EditConflictException"/> with the reason when the text cannot be shown.</summary>
    public List<EditPiece> Build(Place place, EditGlyph anchor, string text)
    {
        var runes = Runes(text);
        var codec = Codec(anchor.Font);
        var pieces = new EditPiece?[runes.Count];
        var missing = new List<int>();
        bool bidi = fonts is not null && Scripts.NeedsBidi(text);
        for (int i = 0; i < runes.Count; i++)
        {
            string r = runes[i];
            if (codec.TryGet(r, out var code) || codec.TryExtend(r, out code)) pieces[i] = Anchored(anchor, r, code);
            else if (r == " ") pieces[i] = new EditPiece { Text = r, Shift = -250, Advance = 0.25 * anchor.FontSize * anchor.Scale, IsSpace = true, Em = 0.25 };
            else missing.Add(i);
        }
        if (bidi) ShapeInStandIn(place, anchor, runes, pieces, missing);
        else if (missing.Count > 0) Substitute(place, anchor, runes, pieces, missing);
        return [.. pieces.Select(p => p!)];
    }

    // The font in the file draws characters one by one in logical order, so text with right-to-left characters goes whole
    // into a stand-in that Items shapes. When no stand-in can be had the pieces stay as they are, unless a glyph is missing anyway.
    private void ShapeInStandIn(Place place, EditGlyph anchor, List<string> runes, EditPiece?[] pieces, List<int> missing)
    {
        var all = new EditPiece?[runes.Count];
        try
        {
            Substitute(place, anchor, runes, all, [.. Enumerable.Range(0, runes.Count)]);
        }
        catch (EditConflictException) when (missing.Count == 0)
        {
            return;
        }
        Array.Copy(all, pieces, all.Length);
    }

    /// <summary>The pieces of <paramref name="text"/> all in a font chosen for the job, drawn at <paramref name="size"/>.</summary>
    public static List<EditPiece> BuildWith(PdfDrawFont draw, string name, EditGlyph anchor, string text, double size) =>
    [
        .. Runes(text).Select(r => new EditPiece
        {
            Text = r,
            Bytes = draw.Encode(r),
            Font = name,
            Draw = draw,
            IsSpace = r == " ",
            Em = draw.Width(r, 1000) / 1000,
            Code32 = r == " " && !draw.IsEmbedded,
            Advance = (draw.Width(r, 1000) / 1000 * size + anchor.CharSpacing + (r == " " && !draw.IsEmbedded ? anchor.WordSpacing : 0)) * anchor.Scale,
        }),
    ];

    private static EditPiece Anchored(EditGlyph anchor, string text, FontCode code) => new()
    {
        Text = text,
        Bytes = code.Bytes,
        IsSpace = text == " ",
        Em = code.Width / 1000,
        Code32 = code.IsSpace,
        Advance = (code.Width / 1000 * anchor.FontSize + anchor.CharSpacing + (code.IsSpace ? anchor.WordSpacing : 0)) * anchor.Scale,
    };

    private void Substitute(Place place, EditGlyph anchor, List<string> runes, EditPiece?[] pieces, List<int> missing)
    {
        if (fonts is null) throw new EditConflictException(EditingText.NoFont);
        var state = place.States.At(anchor.Op);
        if (state.Font is null) throw new EditConflictException(EditingText.FontSetOutside);
        // The whole text goes to the embedder: joined forms depend on the neighbours, so distinct characters would miss them.
        string needed = string.Concat(missing.Select(i => runes[i]));
        var key = (place.Unit, anchor.Font);
        // An edit taken back removes its resources; a stand-in named by one is no longer there.
        bool known = _stand.TryGetValue(key, out var stand) && batch.HasResource(place, stand.Name);
        if (!known) stand = (null!, "", "");
        if (!known || !stand.Covered.Contains(needed, StringComparison.Ordinal))
        {
            string covered = stand.Covered + needed;
            var (families, style) = FontMatch.For(anchor.Font);
            var embedder = new PdfFontEmbedder(document, fonts);
            PdfDrawFont? draw = null;
            string family = families[0];
            foreach (string candidate in families)
            {
                draw = embedder.Add(candidate, style, [covered], embed: anchor.Font.IsEmbedded);
                family = candidate;
                if (draw is not null) break;
            }
            if (draw is null) throw new EditConflictException(EditingText.NoFont);
            if (draw.Missing.Count > 0)
            {
                string absent = string.Concat(draw.Missing.Select(char.ConvertFromUtf32));
                throw new EditConflictException(string.Format(EditingText.NoGlyphs, absent));
            }
            string name = batch.AddResource(place, "Font", draw.Reference) ?? throw new EditConflictException(EditingText.SharedForm);
            _stand[key] = stand = (draw, name, covered);
            _made.Add((new FontSubstitution(anchor.Font.Name, family, string.Concat(needed.EnumerateRunes().Distinct().Select(r => r.ToString())), draw.IsEmbedded), place, name));
        }
        foreach (int i in missing)
        {
            string r = runes[i];
            double width = stand.Draw.Width(r, 1000);
            pieces[i] = new EditPiece
            {
                Text = r,
                Bytes = stand.Draw.Encode(r),
                Font = stand.Name,
                Draw = stand.Draw,
                IsSpace = r == " ",
                Em = width / 1000,
                Code32 = r == " " && !stand.Draw.IsEmbedded,
                Advance = (width / 1000 * anchor.FontSize + anchor.CharSpacing + (r == " " && !stand.Draw.IsEmbedded ? anchor.WordSpacing : 0)) * anchor.Scale,
            };
        }
    }

    /// <summary>
    /// Joins consecutive pieces of one stand-in font with right-to-left characters into one piece, so that it is shaped and
    /// written in display order and measured by what the shaper makes of it. <paramref name="rightToLeft"/> is the direction
    /// of the paragraph the line belongs to; a line that would start the other way gets a direction mark. Pieces
    /// with no such text stay as they are.
    /// </summary>
    internal static List<EditPiece> Shape(IReadOnlyList<EditPiece> pieces, EditGlyph anchor, double? size = null, bool? rightToLeft = null)
    {
        double em = size ?? anchor.FontSize;
        var result = new List<EditPiece>();
        for (int i = 0; i < pieces.Count; i++)
        {
            int end = i + 1;
            if (pieces[i].Draw is { } draw && pieces[i].Shift is null && !pieces[i].IsShaped)
            {
                while (end < pieces.Count && pieces[end].Draw == draw && pieces[end].Font == pieces[i].Font && pieces[end].Shift is null && !pieces[end].IsShaped) end++;
                string text = string.Concat(pieces.Skip(i).Take(end - i).Select(p => p.Text));
                if (Scripts.NeedsBidi(text) && draw.IsEmbedded)
                {
                    if (rightToLeft is { } rtl && draw.IsRightToLeft(text) != rtl) text = (rtl ? (char)0x200F : (char)0x200E) + text;
                    if (draw.Shaped(text) is { } line)
                    {
                        result.Add(new EditPiece
                        {
                            Text = text,
                            Font = pieces[i].Font,
                            Draw = draw,
                            IsShaped = true,
                            Em = line.Width / 1000,
                            Advance = (line.Width / 1000 * em + anchor.CharSpacing * line.Glyphs.Count) * anchor.Scale,
                        });
                        i = end - 1;
                        continue;
                    }
                }
            }
            result.Add(pieces[i]);
        }
        return result;
    }

    /// <summary>
    /// The pieces as show items. A stand-in font is selected before its characters and the font in
    /// force at <paramref name="at"/> selected again after them; <paramref name="before"/> and
    /// <paramref name="after"/> go round the whole text.
    /// </summary>
    public static List<ShowItem> Items(Place place, EditGlyph at, IReadOnlyList<EditPiece> pieces, double shift = 0, byte[]? before = null, byte[]? after = null, double? size = null, ContentOperation? current = null)
    {
        var items = new List<ShowItem>();
        if (before is { Length: > 0 }) items.Add(new ShowOps(before));
        if (shift != 0) items.Add(new ShowShift(-shift));
        var run = new List<byte>();
        string? font = null;
        void Flush()
        {
            if (run.Count > 0) items.Add(new ShowText([.. run]));
            run.Clear();
        }
        void Select(string? next)
        {
            if (next == font) return;
            Flush();
            if (next is not null) items.Add(new ShowOps(new ContentWriter().Font(next, size ?? at.FontSize).ToArray()));
            else items.Add(new ShowOps(new ContentWriter().Add(current ?? place.States.At(at.Op).Font ?? throw new EditConflictException(EditingText.FontSetOutside)).ToArray()));
            font = next;
        }
        foreach (var piece in pieces)
        {
            if (piece.Shift is { } move)
            {
                Select(null);
                Flush();
                items.Add(new ShowShift(move));
                continue;
            }
            Select(piece.Font);
            if (piece.IsShaped)
            {
                Flush();
                items.Add(new ShowOps(new ContentWriter().Show(piece.Draw!, piece.Text, size ?? at.FontSize).ToArray()));
                continue;
            }
            run.AddRange(piece.Bytes);
        }
        Select(null);
        Flush();
        if (after is { Length: > 0 }) items.Add(new ShowOps(after));
        return items;
    }
}
