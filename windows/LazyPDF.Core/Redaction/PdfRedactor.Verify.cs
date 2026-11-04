using System.Text;

namespace LazyPDF.Core;

public sealed partial class PdfRedactor
{
    private const int MaxVerifiedStrings = 500;
    private const long MaxStream = 256L << 20;

    /// <summary>
    /// Opens <paramref name="output"/> again and looks for what should be gone: text extracted from
    /// inside any mark (apart from the <paramref name="overlay"/> texts drawn there), and the
    /// <paramref name="removed"/> strings, in every object and every decoded stream, in Latin-1, UTF-8
    /// and UTF-16. The glyphs of page content are checked by the first test only, since they are
    /// coded by the font and the same words may be shown elsewhere. The problems say where, not what.
    /// </summary>
    public static RedactionVerification Verify(byte[] output, IReadOnlyList<RedactionMark> marks, IReadOnlyCollection<string> removed,
        IReadOnlyCollection<string>? overlay = null, string? password = null)
    {
        var problems = new List<string>();
        PdfDocument document;
        try
        {
            document = PdfDocument.Open(output, password);
        }
        catch (PdfReadException)
        {
            return new RedactionVerification([RedactionText.DoesNotOpen]);
        }
        using (document)
        {
            var shown = (overlay ?? []).Select(NoSpaces).Where(t => t.Length > 0).ToList();
            foreach (var group in marks.Where(m => m.Page < document.Pages.Count).GroupBy(m => m.Page).OrderBy(g => g.Key))
            {
                var areas = group.SelectMany(m => m.Quads).Select(MarkArea.Of).Where(a => a.IsUsable).ToList();
                var text = TextPage.Create(document, document.Pages[group.Key], new TextPageOptions(RemoveDuplicates: false));
                string inside = NoSpaces(string.Concat(text.Chars.Where(c => areas.Any(a => Geometry.GlyphMeets(Geometry.Corners(c.Quad), a))).Select(c => c.Text)));
                foreach (string t in shown.OrderByDescending(t => t.Length)) inside = inside.Replace(t, "", StringComparison.Ordinal);
                if (inside.Length > 0) problems.Add(RedactionText.StillInside(group.Key));
            }
            LookForStrings(document, [.. removed.Take(MaxVerifiedStrings)], problems);
        }
        return new RedactionVerification(problems);
    }

    private static string NoSpaces(string text) => string.Concat(text.Where(c => !char.IsWhiteSpace(c)));

    private static void LookForStrings(PdfDocument document, List<string> strings, List<string> problems)
    {
        if (strings.Count == 0) return;
        var needles = strings.SelectMany(s => new[] { Encoding.Latin1.GetBytes(s), Encoding.UTF8.GetBytes(s), Encoding.BigEndianUnicode.GetBytes(s), Encoding.Unicode.GetBytes(s) })
            .DistinctBy(Convert.ToHexString).ToList();
        var content = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (var page in document.Pages)
        {
            var contents = document.Resolve(page.Dictionary["Contents"]);
            foreach (var item in contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance])
            {
                if (document.Resolve(item) is PdfStream stream) content.Add(stream);
            }
        }

        // Font programs and their code maps stay by design; a few letters of text turn up by chance in their binary data and boilerplate.
        var programs = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not PdfDictionary descriptor) continue;
            foreach (string key in (ReadOnlySpan<string>)["FontFile", "FontFile2", "FontFile3", "ToUnicode"])
            {
                if (document.Resolve(descriptor[key]) is PdfStream program) programs.Add(program);
            }
        }

        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not { } value) continue;
            string where = $"object {number}";
            bool found = Holds(document, value is PdfStream s0 ? s0.Dictionary : value, needles, 0);
            if (!found && value is PdfStream stream && !programs.Contains(stream))
            {
                bool isContent = content.Contains(stream) || document.Name(stream.Dictionary, "Subtype") == "Form" || document.Integer(stream.Dictionary, "PatternType") == 1;
                byte[] data;
                try
                {
                    data = document.Data(stream, MaxStream);
                }
                catch (PdfReadException)
                {
                    data = document.RawData(stream);
                }
                found = isContent ? HoldsInOperands(document, data, needles) : Contains(data, needles);
            }
            if (found) problems.Add(RedactionText.StillInFile(where));
        }
    }

    private static bool Contains(byte[] data, List<byte[]> needles) => needles.Any(n => n.Length > 0 && data.AsSpan().IndexOf(n) >= 0);

    // Strings inside objects: as the bytes they are, and as the text they stand for.
    private static bool Holds(PdfDocument document, PdfObject value, List<byte[]> needles, int depth)
    {
        if (depth > 32) return false;
        switch (value)
        {
            case PdfString s:
                if (Contains(s.Bytes, needles)) return true;
                return Contains(Encoding.BigEndianUnicode.GetBytes(PdfText.Decode(s.Bytes)), needles) || Contains(Encoding.UTF8.GetBytes(PdfText.Decode(s.Bytes)), needles);
            case PdfArray a:
                return a.Items.Any(i => Holds(document, i, needles, depth + 1));
            case PdfDictionary d:
                return d.Entries.Any(e => Holds(document, e.Value, needles, depth + 1));
            default:
                return false;
        }
    }

    // The text shown by the page is checked on the page; what a content stream says besides it
    // (marked content properties, the names of a description) is checked here.
    private static bool HoldsInOperands(PdfDocument document, byte[] data, List<byte[]> needles)
    {
        IReadOnlyList<ContentOperation> operations;
        try
        {
            operations = ContentParser.Parse(data);
        }
        catch (PdfReadException)
        {
            return false;
        }
        foreach (var op in operations)
        {
            if (op.Operator is "Tj" or "TJ" or "'" or "\"") continue;
            if (op.Operands.Any(o => Holds(document, o, needles, 0))) return true;
        }
        return false;
    }
}
