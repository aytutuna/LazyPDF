using System.IO.Compression;
using System.Text;

namespace LazyPDF.Core;

public sealed partial class PdfRedactor
{
    private const int MaxVerifiedStrings = 50_000;
    private const long MaxStream = 256L << 20;
    private const int MaxNested = 2;
    private const int MaxSpoken = 1 << 24;

    /// <summary>
    /// Opens <paramref name="output"/> again and looks for what should be gone: text extracted from
    /// inside any mark (apart from the <paramref name="overlay"/> texts drawn there), and the
    /// <paramref name="removed"/> strings, in every object and every decoded stream, in Latin-1, UTF-8
    /// and UTF-16. The glyphs of page content are checked by the first test only, since they are
    /// coded by the font and the same words may be shown elsewhere. A marked page that <see cref="RedactionWalk"/> cannot
    /// follow to its end is a problem too. The problems say where, not what.
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
                var page = document.Pages[group.Key];
                var walk = new RedactionWalk(document);
                if (text.IsTruncated || !walk.Page(page) || !walk.Annotations(page)) problems.Add(RedactionText.NotFollowed(group.Key));
            }
            if (removed.Count > MaxVerifiedStrings) problems.Add(RedactionText.TooManyStrings);
            LookForStrings(document, [.. removed.Take(MaxVerifiedStrings)], problems);
        }
        return new RedactionVerification(problems);
    }

    private static string NoSpaces(string text) => string.Concat(text.Where(c => !char.IsWhiteSpace(c)));

    private static void LookForStrings(PdfDocument document, List<string> strings, List<string> problems)
    {
        var needles = new Needles(strings.SelectMany(s => new[] { Encoding.Latin1.GetBytes(s), Encoding.UTF8.GetBytes(s), Encoding.BigEndianUnicode.GetBytes(s), Encoding.Unicode.GetBytes(s) })
            .Where(n => n.Length >= 2).DistinctBy(Convert.ToHexString));
        Search(document, needles, problems, 0);
    }

    private static void Search(PdfDocument document, Needles needles, List<string> problems, int nested)
    {
        var content = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        var painted = new HashSet<int>();
        foreach (var page in document.Pages)
        {
            foreach (var stream in RedactionResources.Contents(document, page)) content.Add(stream);
            var walk = new RedactionWalk(document);
            // A page that cannot be followed may paint any of what it reaches.
            if (walk.Page(page))
            {
                if (!walk.Annotations(page)) RedactionObjects.Painted(document, page.Dictionary["Annots"], painted, RedactionObjects.Listing);
                painted.UnionWith(walk.Used);
            }
            else
            {
                RedactionObjects.Painted(document, page.Dictionary, painted, RedactionObjects.Listing);
            }
        }

        // A page of an attached file is read as a viewer would, with its own fonts: the form-by-form reading below knows none of them.
        if (nested > 0)
        {
            foreach (var page in document.Pages)
            {
                bool unreadPage = false;
                if (Speaks(document, (i, v) => i.Run(page, v), needles, ref unreadPage)) problems.Add(RedactionText.StillInFile(RedactionText.PageOf(page.Index)));
                else if (unreadPage) problems.Add(RedactionText.NotChecked(RedactionText.PageOf(page.Index)));
            }
        }

        // Font programs and their code maps stay by design; a few letters of text turn up by chance in their binary data and boilerplate.
        var programs = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        var files = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is PdfObject value) CollectPrograms(document, value is PdfStream s ? s.Dictionary : value, programs, files, 0);
        }

        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not { } value) continue;
            bool attached = value is PdfStream { Dictionary: var d } file && (document.Name(d, "Type") == "EmbeddedFile" || files.Contains(file));
            string where = attached ? RedactionText.AttachedFile(number) : $"object {number}";
            bool unread = false;
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
                    // A picture in an image codec is looked at as the codec's bytes. What else cannot be decoded, or is longer than is read, may hold the word in a form the raw bytes do not.
                    if (InCodec(document, stream) is { } coded) data = coded;
                    else
                    {
                        data = document.RawData(stream);
                        unread = true;
                    }
                }
                // The element and attribute names of an XMP packet are the format's own, and character references hide a word from a search of the raw bytes, so a packet that reads as XML is searched by what it says.
                bool packet = document.Name(stream.Dictionary, "Type") == "Metadata" || document.Name(stream.Dictionary, "Subtype") == "XML";
                // A form that nothing paints, or that is painted where the page scan does not look, is not checked against the page, so the text it shows is looked for here.
                bool unseen = !content.Contains(stream) && !painted.Contains(number);
                found = isContent ? HoldsInOperands(document, data, needles, unseen || nested > 0, ref unread) || (unseen || nested > 0) && Speaks(document, (i, v) => i.Run(stream, v), needles, ref unread)
                    : attached || Container(data) ? HoldsAttached(data, needles, nested, ref unread)
                    : packet && RedactionMetadata.PlainText(data) is { } plain ? needles.In(Encoding.UTF8.GetBytes(plain)) : needles.In(data);
            }
            if (found) problems.Add(RedactionText.StillInFile(where));
            else if (unread) problems.Add(RedactionText.NotChecked(where));
        }
    }

    // The text the form would show, as its fonts decode it: a word split over a TJ array or coded by a subset font does not
    // read as one string in the operands.
    private static bool Speaks(PdfDocument document, Action<ContentInterpreter, ContentVisitor> run, Needles needles, ref bool unread)
    {
        var text = new StringBuilder();
        var interpreter = new ContentInterpreter(document);
        run(interpreter, new Spoken(text));
        unread |= interpreter.IsTruncated || text.Length >= MaxSpoken;
        return needles.In(Encoding.UTF8.GetBytes(text.ToString()));
    }

    private sealed class Spoken(StringBuilder text) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (text.Length < MaxSpoken) text.Append(glyph.Unicode);
        }
    }

    // An attachment can wrap the original in a container the byte search cannot see into: a zip, or a PDF with its streams
    // compressed. A container that cannot be opened, or lies deeper than is followed, is not known to be clean.
    private static bool HoldsAttached(byte[] data, Needles needles, int nested, ref bool unread)
    {
        if (needles.In(data)) return true;
        bool zip = data is [0x50, 0x4B, 3, 4, ..];
        bool gzip = data is [0x1F, 0x8B, ..];
        bool pdf = !zip && !gzip && Encoding.Latin1.GetString(data, 0, Math.Min(data.Length, 1024)).Contains("%PDF-", StringComparison.Ordinal);
        // Compressed or encrypted data in a format that is not opened here hides whatever is in it.
        if (Unopened.Any(m => data.AsSpan().StartsWith(m)) || !zip && !gzip && !pdf && !Media.Any(m => data.AsSpan().StartsWith(m)) && Dense(data))
        {
            unread = true;
            return false;
        }
        if (nested >= MaxNested)
        {
            unread |= zip || gzip || pdf;
            return false;
        }
        try
        {
            if (zip)
            {
                using var archive = new ZipArchive(new MemoryStream(data));
                long budget = MaxStream;
                foreach (var entry in archive.Entries)
                {
                    if (entry.Length > budget)
                    {
                        unread = true;
                        continue;
                    }
                    using var inflated = entry.Open();
                    var bytes = new MemoryStream();
                    var chunk = new byte[1 << 16];
                    for (int n; (n = inflated.Read(chunk)) > 0 && bytes.Length <= budget;) bytes.Write(chunk, 0, n);
                    if (bytes.Length > budget)
                    {
                        unread = true;
                        continue;
                    }
                    budget -= bytes.Length;
                    if (HoldsAttached(bytes.ToArray(), needles, nested + 1, ref unread)) return true;
                }
            }
            else if (gzip)
            {
                using var inflated = new GZipStream(new MemoryStream(data), CompressionMode.Decompress);
                var bytes = new MemoryStream();
                var chunk = new byte[1 << 16];
                for (int n; (n = inflated.Read(chunk)) > 0 && bytes.Length <= MaxStream;) bytes.Write(chunk, 0, n);
                if (bytes.Length > MaxStream) unread = true;
                else return HoldsAttached(bytes.ToArray(), needles, nested + 1, ref unread);
            }
            else if (pdf)
            {
                var problems = new List<string>();
                using var inner = PdfDocument.Open(data);
                Search(inner, needles, problems, nested + 1);
                return problems.Count > 0;
            }
        }
        catch (Exception e) when (e is PdfReadException or InvalidDataException)
        {
            unread = true;
        }
        return false;
    }

    private static readonly byte[][] Unopened =
    [
        [0x42, 0x5A, 0x68], [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0], [0x37, 0x7A, 0xBC, 0xAF], [0x52, 0x61, 0x72, 0x21], [0x28, 0xB5, 0x2F, 0xFD], [0x04, 0x22, 0x4D, 0x18], [0x1F, 0x9D], [0x4C, 0x5A, 0x49, 0x50],
    ];

    // Formats that keep their text in the clear or hold none worth the search.
    private static readonly byte[][] Media =
    [
        [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF], [0x47, 0x49, 0x46, 0x38], [0x52, 0x49, 0x46, 0x46], [0xD0, 0xCF, 0x11, 0xE0], [0x49, 0x44, 0x33], [0x4F, 0x67, 0x67, 0x53],
    ];

    // Whether the data starts like something HoldsAttached opens or knows it cannot, wherever it is held.
    private static bool Container(byte[] data) =>
        data is [0x50, 0x4B, 3, 4, ..] or [0x1F, 0x8B, ..] || Unopened.Any(m => data.AsSpan().StartsWith(m)) || data.AsSpan(0, Math.Min(data.Length, 1024)).IndexOf("%PDF-"u8) >= 0;

    // Bytes that look random: compressed or encrypted, whatever the format.
    private static bool Dense(byte[] data)
    {
        if (data.Length < 512) return false;
        var counts = new int[256];
        int length = Math.Min(data.Length, 1 << 16);
        for (int i = 0; i < length; i++) counts[data[i]]++;
        return counts.Where(c => c > 0).Sum(c => -(double)c / length * Math.Log2((double)c / length)) > 7.2;
    }

    private static byte[]? InCodec(PdfDocument document, PdfStream stream)
    {
        try
        {
            var (filter, parameters, _) = document.DecodeSpec(stream);
            return PdfFilters.DecodeToCodec(document.RawData(stream), filter, parameters, MaxStream) is { Codec: not null } decoded ? decoded.Data : null;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // Looks up every position of the data by its first two bytes, so that many strings cost no more than a few.
    private sealed class Needles
    {
        private readonly bool[] _starts = new bool[1 << 16];
        private readonly Dictionary<int, List<byte[]>> _byStart = [];

        public Needles(IEnumerable<byte[]> strings)
        {
            foreach (var n in strings)
            {
                int key = n[0] << 8 | n[1];
                _starts[key] = true;
                if (!_byStart.TryGetValue(key, out var list)) _byStart[key] = list = [];
                list.Add(n);
            }
        }

        public bool In(ReadOnlySpan<byte> data)
        {
            for (int i = 0; i + 1 < data.Length; i++)
            {
                int key = data[i] << 8 | data[i + 1];
                if (!_starts[key]) continue;
                foreach (var n in _byStart[key])
                {
                    if (data[i..].StartsWith(n)) return true;
                }
            }
            return false;
        }
    }

    // Strings inside objects: as the bytes they are, and as the text they stand for.
    // Descriptors can be direct dictionaries inside a font.
    // Attached files are named by /EF whether or not their stream says what it is.
    private static void CollectPrograms(PdfDocument document, PdfObject value, HashSet<PdfStream> programs, HashSet<PdfStream> files, int depth)
    {
        if (depth > 8) return;
        switch (value)
        {
            case PdfDictionary dictionary:
                bool font = IsFont(document, dictionary);
                foreach (var (key, item) in dictionary.Entries)
                {
                    if (font && key is "FontFile" or "FontFile2" or "FontFile3" or "ToUnicode" && document.Resolve(item) is PdfStream program) programs.Add(program);
                    else if (key == "EF" && document.Resolve(item) is PdfDictionary held)
                    {
                        foreach (var (_, file) in held.Entries)
                        {
                            if (document.Resolve(file) is PdfStream attached) files.Add(attached);
                        }
                    }
                    else CollectPrograms(document, item, programs, files, depth + 1);
                }
                break;
            case PdfArray array:
                foreach (var item in array.Items) CollectPrograms(document, item, programs, files, depth + 1);
                break;
        }
    }

    // The keys of a font hold programs and a character set that are exempt; the same keys anywhere else are data like any other.
    private static bool IsFont(PdfDocument document, PdfDictionary dictionary) =>
        document.Name(dictionary, "Type") is "Font" or "FontDescriptor" || document.Name(dictionary, "Subtype") is "Type1" or "MMType1" or "TrueType" or "Type3" or "Type0" or "CIDFontType0" or "CIDFontType2";

    private static bool Holds(PdfDocument document, PdfObject value, Needles needles, int depth)
    {
        if (depth > RedactionMetadata.ObjectDepth) return false;
        switch (value)
        {
            case PdfString s:
                if (needles.In(s.Bytes)) return true;
                return needles.In(Encoding.BigEndianUnicode.GetBytes(PdfText.Decode(s.Bytes))) || needles.In(Encoding.UTF8.GetBytes(PdfText.Decode(s.Bytes)));
            case PdfName n:
                return Spelled(n.Value, needles);
            case PdfArray a:
                return a.Items.Any(i => Holds(document, i, needles, depth + 1));
            case PdfDictionary d:
                return d.Entries.Any(e => !(e.Key == "CharSet" && IsFont(document, d)) && (Spelled(e.Key, needles) || !RedactionMetadata.IsFontName(e.Key, e.Value) && Holds(document, e.Value, needles, depth + 1)));
            default:
                return false;
        }
    }

    // Names that hold words, such as the keys of the old-style destinations, as opposed to the names the format defines.
    private static bool Spelled(string name, Needles needles) => RedactionMetadata.IsFreeText(name) && needles.In(Encoding.UTF8.GetBytes(RedactionMetadata.NameText(name)));

    // The text shown by the page is checked on the page; what a content stream says besides it
    // (marked content properties, the names of a description) is checked here.
    private static bool HoldsInOperands(PdfDocument document, byte[] data, Needles needles, bool shows, ref bool unread)
    {
        IReadOnlyList<ContentOperation> operations;
        try
        {
            operations = ContentParser.Parse(data);
        }
        catch (PdfReadException)
        {
            unread = true;
            return false;
        }
        foreach (var op in operations)
        {
            if (!shows && op.Operator is "Tj" or "TJ" or "'" or "\"") continue;
            if (op.Operands.Any(o => Holds(document, o, needles, 0))) return true;
        }
        return false;
    }
}
