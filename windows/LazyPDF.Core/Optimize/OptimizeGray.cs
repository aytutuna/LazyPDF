using System.IO.Compression;
using System.Text;

namespace LazyPDF.Core;

// Turns colour into gray: the colour operators of every content stream and the pixels of the
// image XObjects. Shadings, spot colours, Lab and patterns have no gray twin that keeps their
// look, so they stay and are counted.
//
// A form takes its colour space from whoever paints it, so the content is simulated twice. The first
// pass rewrites nothing and learns which spaces reach each form; where a form has to keep its operands
// (a caller's space is a Lab or DeviceN one), the callers that would turn their cs gray hold it back.
internal sealed class OptimizeGray(PdfDocument document, IImageCodec? codec, int jpegQuality)
{
    // Alien is a space of three or more components that gray cannot stand in for, or one that was not found.
    private enum Space { Gray, Rgb, Cmyk, Alien, Other, Inherited }

    private readonly record struct Origin(PdfStream Stream, int At);

    private readonly record struct Slot(Space Space, Origin? At);

    private sealed record Entry(PdfDictionary? Resources, Slot Fill, Slot Stroke);

    private sealed class State
    {
        public Slot Fill, Stroke;
        public readonly Stack<(Slot, Slot)> Saved = new();
    }

    private const long MaxPixels = 32_000_000;

    // Component counts of the Lab and DeviceN spaces in the file that an operand count could be mistaken for RGB or CMYK.
    private readonly HashSet<int> _alien = [];

    // Colour operators that stay as written, because a form or a shared stream needs the space they set.
    private readonly HashSet<Origin> _held = [];
    private readonly HashSet<PdfStream> _frozen = new(ReferenceEqualityComparer.Instance), _simulated = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfStream, Entry> _entries = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfStream, byte[]> _output = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfStream, int> _maskUsers = new(ReferenceEqualityComparer.Instance);

    // Learned by the first pass. An edge is a form painted while its own colour was still its caller's; a paint is
    // a form painted in a space some operator set. Callers hold the spaces that reach a form, for fill or stroke.
    private readonly List<(PdfStream From, PdfStream To, bool Stroke)> _edges = [];
    private readonly HashSet<(PdfStream Form, bool Stroke, Slot Slot)> _paints = [];
    private readonly HashSet<(PdfStream Form, bool Stroke)> _consumers = [];
    private readonly Dictionary<(PdfStream Form, bool Stroke), HashSet<Space>> _callers = new();
    private bool _analysing;

    public int Streams { get; private set; }
    public int Images { get; private set; }
    public int Left { get; private set; }
    public bool NeedsCodec { get; private set; }

    public void Run()
    {
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            foreach (var (_, space) in document.Dict(dictionary, "ColorSpace")?.Entries ?? [])
            {
                var (family, components) = ImageKit.Describe(document, space);
                if (family is ImageFamily.Lab or ImageFamily.Spot && components >= 3) _alien.Add(components);
            }
        }
        var pages = new List<(PdfDictionary? Resources, List<PdfStream> Streams, bool Straddles)>();
        var used = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (var page in document.Pages)
        {
            var contents = document.Resolve(page.Dictionary["Contents"]);
            var streams = (contents is PdfArray list ? list.Items : [contents ?? PdfNull.Instance]).Select(document.Resolve).OfType<PdfStream>().ToList();
            bool straddles = Straddles(streams);
            if (straddles) _frozen.UnionWith(streams);
            used.UnionWith(streams);
            pages.Add((page.Resources, streams, straddles));
        }
        var all = PdfGraph.Objects(document).Select(o => o.Value).OfType<PdfStream>().ToList();
        var forms = all.Where(s => !used.Contains(s) && OptimizeWalk.IsForm(document, s) && document.Integer(s.Dictionary, "PaintType") != 2).ToList();
        foreach (var stream in all)
        {
            if (document.Resolve(stream.Dictionary["SMask"]) is PdfStream soft) _maskUsers[soft] = _maskUsers.GetValueOrDefault(soft) + 1;
        }

        _analysing = true;
        Pass(pages, forms);
        Settle();
        _analysing = false;
        Left = 0;
        Pass(pages, forms);
        foreach (var (stream, data) in _output)
        {
            PdfGraph.SetData(stream, data);
            Streams++;
        }
        foreach (var stream in all)
        {
            var dictionary = stream.Dictionary;
            if (document.Integer(dictionary, "PatternType") == 2) Left++;
            else if (document.Name(dictionary, "Subtype") == "Image" && document.Bool(dictionary, "ImageMask") != true) GrayImage(stream);
        }
    }

    private void Pass(List<(PdfDictionary? Resources, List<PdfStream> Streams, bool Straddles)> pages, List<PdfStream> forms)
    {
        foreach (var (resources, streams, straddles) in pages)
        {
            if (straddles)
            {
                Left++;
                continue;
            }
            var state = new State { Fill = new Slot(Space.Gray, null), Stroke = new Slot(Space.Gray, null) };
            foreach (var stream in streams)
            {
                if (_analysing) NoteContext(stream, new Entry(resources, state.Fill, state.Stroke));
                bool again = !_analysing && !_simulated.Add(stream);
                int before = Left;
                Convert(stream, resources, state);
                // A stream on several pages is run for each page's state but counted once.
                if (again) Left = before;
            }
        }
        foreach (var form in forms)
        {
            var inherited = new Slot(Space.Inherited, null);
            Convert(form, document.Dict(form.Dictionary, "Resources"), new State { Fill = inherited, Stroke = inherited });
        }
    }

    // A stream shared by pages is rewritten once, so it must read the same on each: the same resources and the
    // same colour spaces coming in. Otherwise it stays as it is, and so do the operators that set what it takes in.
    private void NoteContext(PdfStream stream, Entry entry)
    {
        if (!_entries.TryAdd(stream, entry) && _entries[stream] != entry && _frozen.Add(stream)) Hold(_entries[stream]);
        if (_frozen.Contains(stream)) Hold(entry);
    }

    private void Hold(Entry entry)
    {
        if (entry.Fill.At is { } fill) _held.Add(fill);
        if (entry.Stroke.At is { } stroke) _held.Add(stroke);
    }

    private void Settle()
    {
        var calls = _edges.ToLookup(e => (e.From, e.Stroke), e => e.To);
        var work = new Queue<(PdfStream Form, bool Stroke, Space Space)>(_paints.Select(p => (p.Form, p.Stroke, p.Slot.Space)));
        while (work.Count > 0)
        {
            var (form, stroke, space) = work.Dequeue();
            if (!_callers.TryGetValue((form, stroke), out var spaces)) _callers[(form, stroke)] = spaces = [];
            if (!spaces.Add(space)) continue;
            foreach (var next in calls[(form, stroke)]) work.Enqueue((next, stroke, space));
        }
        // A form that keeps its operands holds back every caller on the way to it that would rewrite its cs.
        var callers = _edges.ToLookup(e => (e.To, e.Stroke), e => e.From);
        var keeping = new Queue<(PdfStream Form, bool Stroke)>(_consumers.Where(c => _callers.TryGetValue(c, out var spaces) && spaces.Contains(Space.Alien)));
        var reaching = new HashSet<(PdfStream, bool)>();
        while (keeping.Count > 0)
        {
            var (form, stroke) = keeping.Dequeue();
            if (!reaching.Add((form, stroke))) continue;
            foreach (var caller in callers[(form, stroke)]) keeping.Enqueue((caller, stroke));
        }
        foreach (var (form, stroke, slot) in _paints)
        {
            if (slot.At is { } at && slot.Space is Space.Rgb or Space.Cmyk && reaching.Contains((form, stroke))) _held.Add(at);
        }
    }

    // Whether an operand-counted colour in a form stays: its callers include a Lab or DeviceN space, or none is known and the file holds one that size.
    private bool Keeps(PdfStream form, bool stroke, int operands)
    {
        var spaces = _callers.GetValueOrDefault((form, stroke)) ?? [];
        return spaces.Contains(Space.Alien) || (!spaces.Contains(Space.Rgb) && !spaces.Contains(Space.Cmyk) && _alien.Contains(operands));
    }

    // An operator may sit in a later stream than its operands (7.8.2), and each stream is rewritten on its own.
    private bool Straddles(List<PdfStream> streams)
    {
        if (streams.Count < 2) return false;
        var joined = new MemoryStream();
        var ends = new List<int>();
        try
        {
            foreach (var stream in streams)
            {
                joined.Write(document.Data(stream));
                ends.Add((int)joined.Length);
                joined.WriteByte((byte)'\n');
            }
            foreach (var op in ContentParser.Parse(joined.ToArray()))
            {
                int at = ends.BinarySearch(op.Start);
                at = at < 0 ? ~at : at + 1;
                if (at < ends.Count && op.End > ends[at]) return true;
            }
        }
        catch (PdfReadException)
        {
        }
        return false;
    }

    private void Convert(PdfStream stream, PdfDictionary? resources, State state)
    {
        byte[] data;
        IReadOnlyList<ContentOperation> operations;
        try
        {
            data = document.Data(stream);
            operations = ContentParser.Parse(data);
        }
        catch (PdfReadException)
        {
            return;
        }
        var output = new MemoryStream();
        int copied = 0;
        bool changed = false, frozen = _frozen.Contains(stream);
        void Replace(ContentOperation op, string text)
        {
            if (_analysing || frozen) return;
            output.Write(data, copied, op.Start - copied);
            output.Write(Encoding.Latin1.GetBytes(text));
            copied = op.End;
            changed = true;
        }

        // The state keeps the space the operands are written for, which the colours that follow still need. An
        // operator that cannot be rewritten leaves its space as it was, and so everything written for it.
        Slot Set(ContentOperation op, Space space, string? replacement)
        {
            var at = new Origin(stream, op.Start);
            if (space is Space.Rgb or Space.Cmyk && !_analysing && (replacement is null || frozen || _held.Contains(at)))
            {
                Left++;
                return new Slot(Space.Alien, at);
            }
            if (replacement is not null) Replace(op, replacement);
            return new Slot(space, at);
        }

        foreach (var op in operations)
        {
            switch (op.Operator)
            {
                case "q":
                    state.Saved.Push((state.Fill, state.Stroke));
                    break;
                case "Q" when state.Saved.Count > 0:
                    (state.Fill, state.Stroke) = state.Saved.Pop();
                    break;
                case "g" or "rg" or "k" or "G" or "RG" or "K":
                {
                    bool stroke = char.IsUpper(op.Operator[0]);
                    char kind = char.ToLowerInvariant(op.Operator[0]);
                    var model = kind == 'g' ? Space.Gray : kind == 'r' ? Space.Rgb : Space.Cmyk;
                    double? level = model == Space.Gray ? null : Gray(op, model == Space.Rgb ? 3 : 4);
                    var set = Set(op, model, level is { } y ? $"{Format(y)} {(stroke ? "G" : "g")}" : null);
                    if (stroke) state.Stroke = set;
                    else state.Fill = set;
                    break;
                }
                case "cs" or "CS":
                {
                    var space = SpaceOf(op, resources);
                    var set = Set(op, space, space is Space.Rgb or Space.Cmyk ? $"/DeviceGray {op.Operator}" : null);
                    if (op.Operator == "cs") state.Fill = set;
                    else state.Stroke = set;
                    break;
                }
                case "sc" or "scn" or "SC" or "SCN":
                {
                    bool upper = char.IsUpper(op.Operator[0]);
                    var current = (upper ? state.Stroke : state.Fill).Space;
                    bool inherited = current == Space.Inherited;
                    int count = op.Operands.Count;
                    int needed = current == Space.Rgb || (inherited && count == 3) ? 3 : current == Space.Cmyk || (inherited && count == 4) ? 4 : 0;
                    if (needed == 0 || !op.Operands.All(o => o is PdfNumber) || Gray(op, needed) is not { } shade) break;
                    if (!inherited) Replace(op, $"{Format(shade)} {op.Operator}");
                    else if (_analysing) _consumers.Add((stream, upper));
                    else if (Keeps(stream, upper, needed)) Left++;
                    // g and G set their own space; the state stays inherited so the next colour is judged the same way.
                    else Replace(op, $"{Format(shade)} {(upper ? "G" : "g")}");
                    break;
                }
                case "Do" when _analysing && op.Operands.Count > 0 && op.Operands[0] is PdfName xobject
                    && document.Resolve(document.Dict(resources, "XObject")?[xobject.Value]) is PdfStream form:
                    foreach (bool stroke in new[] { false, true })
                    {
                        var held = stroke ? state.Stroke : state.Fill;
                        if (held.Space == Space.Inherited) _edges.Add((stream, form, stroke));
                        else _paints.Add((form, stroke, held));
                    }
                    break;
                case "sh":
                    Left++;
                    break;
                case "BI" when op.Image is { } image && !IsGrayInline(image):
                    Left++;
                    break;
            }
        }
        if (!changed) return;
        output.Write(data, copied, data.Length - copied);
        _output.TryAdd(stream, output.ToArray());
    }

    private static bool IsGrayInline(InlineImage image) =>
        (image.Dictionary["CS"] ?? image.Dictionary["ColorSpace"]) is PdfName { Value: "G" or "DeviceGray" } || image.Dictionary["IM"] is PdfBoolean { Value: true } || image.Dictionary["ImageMask"] is PdfBoolean { Value: true };

    private static string Format(double value) => new PdfNumber(Math.Clamp(value, 0, 1)).Text;

    // Luminance of the last n operands as RGB, or of CMYK taken the way the filters do (1 - c)(1 - k).
    private static double? Gray(ContentOperation op, int n)
    {
        if (op.Operands.Count < n) return null;
        var v = new double[n];
        for (int i = 0; i < n; i++)
        {
            if (op.Operands[op.Operands.Count - n + i] is not PdfNumber number) return null;
            v[i] = Math.Clamp(number.Value, 0, 1);
        }
        return Luminance(v);
    }

    private static double Luminance(double[] v) => v.Length switch
    {
        1 => v[0],
        3 => 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2],
        _ => (1 - v[3]) * (1 - (0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2])),
    };

    // The matte is a colour in the image's space, so it follows the image to gray. Looked up before the
    // image changes: an indexed image's matte is a palette index (11.6.5.3).
    private double? MatteGray(PdfDictionary image, ImageFamily family, int components)
    {
        if (document.Resolve(image["SMask"]) is not PdfStream soft || document.Array(soft.Dictionary, "Matte") is not { } matte || matte.Items.Count != components) return null;
        var values = matte.Items.Select(i => document.Resolve(i) is PdfNumber n ? n.Value : 0).ToArray();
        if (family != ImageFamily.Indexed) return Luminance([.. values.Select(v => Math.Clamp(v, 0, 1))]);
        var entry = image.Copy();
        foreach (string key in new[] { "SMask", "Mask", "Decode" }) entry.Remove(key);
        entry["Width"] = entry["Height"] = new PdfNumber(1);
        entry["BitsPerComponent"] = new PdfNumber(8);
        try
        {
            var pixel = PdfImageSamples.ToRgba(entry, [(byte)Math.Clamp(values[0], 0, 255)], document.Resolve, s => document.Data(s)).Rgba;
            return ImageKit.Luminance(pixel[0], pixel[1], pixel[2]) / 255.0;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // The matte has one value per component of the image it belongs to, so a mask that two images use cannot follow just one of them.
    private bool SharesMatte(PdfDictionary image) =>
        document.Resolve(image["SMask"]) is PdfStream soft && soft.Dictionary.ContainsKey("Matte") && _maskUsers.GetValueOrDefault(soft) > 1;

    private void SetMatte(PdfDictionary image, double gray, int components)
    {
        var soft = (PdfStream)document.Resolve(image["SMask"])!;
        soft.Dictionary["Matte"] = new PdfArray([.. Enumerable.Repeat<PdfObject>(new PdfNumber(gray), components)]);
    }

    private Space SpaceOf(ContentOperation op, PdfDictionary? resources)
    {
        if (op.Operands.Count == 0 || op.Operands[0] is not PdfName name) return Space.Other;
        PdfObject? definition = name;
        if (name.Value is not ("DeviceGray" or "DeviceRGB" or "DeviceCMYK" or "Pattern"))
        {
            definition = document.Resolve(document.Dict(resources, "ColorSpace")?[name.Value]);
            if (definition is null)
            {
                // The colour stays whatever space the caller meant by the name.
                Left++;
                return Space.Alien;
            }
        }
        if (name.Value == "Pattern" || (definition is PdfArray { Items.Count: > 0 } array && document.Resolve(array.Items[0]) is PdfName { Value: "Pattern" })) return Space.Other;
        var (family, components) = ImageKit.Describe(document, definition);
        if (family is ImageFamily.Spot or ImageFamily.Lab) Left++;
        return family switch
        {
            ImageFamily.Gray => Space.Gray,
            ImageFamily.Rgb => Space.Rgb,
            ImageFamily.Cmyk => Space.Cmyk,
            ImageFamily.Unknown => Space.Alien,
            _ => components >= 3 ? Space.Alien : Space.Other,
        };
    }

    private void GrayImage(PdfStream stream)
    {
        var dictionary = stream.Dictionary;
        var (family, components) = ImageKit.Describe(document, dictionary["ColorSpace"]);
        if (family is ImageFamily.Gray or ImageFamily.Unknown) return;
        int width = (int)(document.Integer(dictionary, "Width") ?? 0), height = (int)(document.Integer(dictionary, "Height") ?? 0);
        if (family is ImageFamily.Spot or ImageFamily.Lab || width < 1 || height < 1 || (long)width * height > MaxPixels || document.Resolve(dictionary["Mask"]) is PdfArray || SharesMatte(dictionary))
        {
            Left++;
            return;
        }
        var (filter, parameters, _) = document.DecodeSpec(stream);
        PdfRgbaImage pixels;
        string? coded;
        try
        {
            var decoded = PdfFilters.DecodeToCodec(document.RawData(stream), filter, parameters);
            coded = decoded.Codec;
            if (coded is null)
            {
                var plain = dictionary.Copy();
                plain.Remove("SMask");
                plain.Remove("Mask");
                pixels = PdfImageSamples.ToRgba(plain, decoded.Data, document.Resolve, s => document.Data(s));
            }
            else if (coded is "DCTDecode" or "JPXDecode" && !dictionary.ContainsKey("Decode") && codec is not null && codec.Decode(decoded.Data, coded) is { } image)
            {
                pixels = image;
            }
            else
            {
                if (coded is "DCTDecode" or "JPXDecode" && codec is null) NeedsCodec = true;
                Left++;
                return;
            }
        }
        catch (PdfReadException)
        {
            Left++;
            return;
        }
        double? matte = MatteGray(dictionary, family, components);
        var gray = new byte[pixels.Width * pixels.Height];
        for (int i = 0; i < gray.Length; i++) gray[i] = ImageKit.Luminance(pixels.Rgba[4 * i], pixels.Rgba[4 * i + 1], pixels.Rgba[4 * i + 2]);
        if (coded is null)
        {
            stream.Data = PdfFilterEncoders.Flate(gray, CompressionLevel.SmallestSize);
            dictionary["Filter"] = new PdfName("FlateDecode");
            dictionary["ColorSpace"] = new PdfName("DeviceGray");
        }
        else
        {
            var rgba = new byte[gray.Length * 4];
            for (int i = 0; i < gray.Length; i++) (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = (gray[i], gray[i], gray[i], 255);
            stream.Data = codec!.EncodeJpeg(new PdfRgbaImage(pixels.Width, pixels.Height, rgba), Math.Clamp(jpegQuality, 1, 100));
            dictionary["Filter"] = new PdfName("DCTDecode");
            dictionary["ColorSpace"] = new PdfName("DeviceRGB");
            dictionary["Width"] = new PdfNumber(pixels.Width);
            dictionary["Height"] = new PdfNumber(pixels.Height);
        }
        dictionary["BitsPerComponent"] = new PdfNumber(8);
        dictionary.Remove("DecodeParms");
        dictionary.Remove("Decode");
        if (matte is { } level) SetMatte(dictionary, level, coded is null ? 1 : 3);
        Images++;
    }
}
