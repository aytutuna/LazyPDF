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

    public bool IsSpace { get; init; }

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
        for (int i = 0; i < runes.Count; i++)
        {
            string r = runes[i];
            if (codec.TryGet(r, out var code) || codec.TryExtend(r, out code)) pieces[i] = Anchored(anchor, r, code);
            else if (r == " ") pieces[i] = new EditPiece { Text = r, Shift = -250, Advance = 0.25 * anchor.FontSize * anchor.Scale, IsSpace = true, Em = 0.25 };
            else missing.Add(i);
        }
        if (missing.Count > 0) Substitute(place, anchor, runes, pieces, missing);
        return [.. pieces.Select(p => p!)];
    }

    /// <summary>The pieces of <paramref name="text"/> all in a font chosen for the job, drawn at <paramref name="size"/>.</summary>
    public static List<EditPiece> BuildWith(PdfDrawFont draw, string name, EditGlyph anchor, string text, double size) =>
    [
        .. Runes(text).Select(r => new EditPiece
        {
            Text = r,
            Bytes = draw.Encode(r),
            Font = name,
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
        string needed = string.Concat(missing.Select(i => runes[i]).Distinct());
        var key = (place.Unit, anchor.Font);
        // An edit taken back removes its resources; a stand-in named by one is no longer there.
        bool known = _stand.TryGetValue(key, out var stand) && batch.HasResource(place, stand.Name);
        if (!known) stand = (null!, "", "");
        if (!known || !needed.EnumerateRunes().All(stand.Covered.EnumerateRunes().ToHashSet().Contains))
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
            _made.Add((new FontSubstitution(anchor.Font.Name, family, needed, draw.IsEmbedded), place, name));
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
                IsSpace = r == " ",
                Em = width / 1000,
                Code32 = r == " " && !stand.Draw.IsEmbedded,
                Advance = (width / 1000 * anchor.FontSize + anchor.CharSpacing + (r == " " && !stand.Draw.IsEmbedded ? anchor.WordSpacing : 0)) * anchor.Scale,
            };
        }
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
            run.AddRange(piece.Bytes);
        }
        Select(null);
        Flush();
        if (after is { Length: > 0 }) items.Add(new ShowOps(after));
        return items;
    }
}
