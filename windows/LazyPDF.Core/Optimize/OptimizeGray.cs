using System.IO.Compression;
using System.Text;

namespace LazyPDF.Core;

// Turns colour into gray: the colour operators of every content stream and the pixels of the
// image XObjects. Shadings, spot colours, Lab and patterns have no gray twin that keeps their
// look, so they stay and are counted.
internal sealed class OptimizeGray(PdfDocument document, IImageCodec? codec, int jpegQuality)
{
    private enum Space { Gray, Rgb, Cmyk, Other, Pattern, Unknown, Inherited }

    private sealed class State
    {
        public Space Fill, Stroke;
        public readonly Stack<(Space, Space)> Saved = new();
    }

    private const long MaxPixels = 32_000_000;

    // Component counts of the Lab and DeviceN spaces in the file that an operand count could be mistaken for RGB or CMYK.
    private readonly HashSet<int> _alien = [];

    // Forms painted while a caller's colour space was a Lab, DeviceN or similar one, or an RGB or CMYK one that cs turns gray.
    private readonly HashSet<PdfStream> _keptFor = new(ReferenceEqualityComparer.Instance), _convertedFor = new(ReferenceEqualityComparer.Instance);

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
        var done = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (var page in document.Pages)
        {
            var state = new State { Fill = Space.Gray, Stroke = Space.Gray };
            var contents = document.Resolve(page.Dictionary["Contents"]);
            var streams = (contents is PdfArray list ? list.Items : [contents ?? PdfNull.Instance])
                .Select(document.Resolve).OfType<PdfStream>().Where(done.Add).ToList();
            if (Straddles(streams))
            {
                Left++;
                continue;
            }
            foreach (var stream in streams) Convert(stream, page.Resources, state);
        }
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            if (value is not PdfStream stream || !done.Add(stream)) continue;
            var dictionary = stream.Dictionary;
            if (document.Name(dictionary, "Subtype") == "Form" || (document.Integer(dictionary, "PatternType") == 1 && document.Integer(dictionary, "PaintType") != 2))
            {
                Convert(stream, document.Dict(dictionary, "Resources"), new State { Fill = Space.Inherited, Stroke = Space.Inherited });
            }
            else if (document.Integer(dictionary, "PatternType") == 2) Left++;
            else if (document.Name(dictionary, "Subtype") == "Image" && document.Bool(dictionary, "ImageMask") != true) GrayImage(stream);
        }
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
        bool changed = false;
        void Replace(ContentOperation op, string text)
        {
            output.Write(data, copied, op.Start - copied);
            output.Write(Encoding.Latin1.GetBytes(text));
            copied = op.End;
            changed = true;
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
                    bool stroke = char.IsUpper(op.Operator[0]);
                    var plain = Gray(op, op.Operator.ToLowerInvariant() switch { "g" => 1, "rg" => 3, _ => 4 });
                    if (stroke) state.Stroke = Space.Gray;
                    else state.Fill = Space.Gray;
                    if (plain is { } y && op.Operator is not ("g" or "G")) Replace(op, $"{Format(y)} {(stroke ? "G" : "g")}");
                    break;
                case "cs" or "CS":
                    var space = SpaceOf(op, resources);
                    // The state keeps the colour space the operands are written for, which the colours that follow still need.
                    if (space is Space.Rgb or Space.Cmyk) Replace(op, $"/DeviceGray {op.Operator}");
                    if (op.Operator == "cs") state.Fill = space;
                    else state.Stroke = space;
                    break;
                case "sc" or "scn" or "SC" or "SCN":
                    bool upper = char.IsUpper(op.Operator[0]);
                    var current = upper ? state.Stroke : state.Fill;
                    bool inherited = current == Space.Inherited;
                    int count = op.Operands.Count;
                    int needed = current == Space.Rgb || (inherited && count == 3) ? 3 : current == Space.Cmyk || (inherited && count == 4) ? 4 : 0;
                    if (needed == 0 || !op.Operands.All(o => o is PdfNumber) || Gray(op, needed) is not { } y2) break;
                    if (!inherited)
                    {
                        Replace(op, $"{Format(y2)} {op.Operator}");
                        break;
                    }
                    // The caller's space is a guess from the operand count unless a caller was seen; a Lab or DeviceN space of that size makes it a bad one.
                    bool kept = _keptFor.Contains(stream), converted = _convertedFor.Contains(stream);
                    if (kept || (!converted && _alien.Contains(needed)))
                    {
                        Left++;
                        break;
                    }
                    // g and G set their own space; the state stays inherited so the next colour is judged the same way.
                    Replace(op, $"{Format(y2)} {(upper ? "G" : "g")}");
                    break;
                case "Do" when state.Fill != Space.Inherited && op.Operands.Count > 0 && op.Operands[0] is PdfName xobject
                    && document.Resolve(document.Dict(resources, "XObject")?[xobject.Value]) is PdfStream form:
                    foreach (var held in new[] { state.Fill, state.Stroke })
                    {
                        if (held is Space.Other) _keptFor.Add(form);
                        else if (held is Space.Rgb or Space.Cmyk) _convertedFor.Add(form);
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
        PdfGraph.SetData(stream, output.ToArray());
        Streams++;
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

    private void SetMatte(PdfDictionary image, double gray, int components)
    {
        var soft = (PdfStream)document.Resolve(image["SMask"])!;
        soft.Dictionary["Matte"] = new PdfArray([.. Enumerable.Repeat<PdfObject>(new PdfNumber(gray), components)]);
    }

    private Space SpaceOf(ContentOperation op, PdfDictionary? resources)
    {
        if (op.Operands.Count == 0 || op.Operands[0] is not PdfName name) return Space.Unknown;
        PdfObject? definition = name;
        if (name.Value is not ("DeviceGray" or "DeviceRGB" or "DeviceCMYK" or "Pattern"))
        {
            definition = document.Resolve(document.Dict(resources, "ColorSpace")?[name.Value]);
            if (definition is null)
            {
                // The colour stays whatever space the caller meant by the name.
                Left++;
                return Space.Unknown;
            }
        }
        if (name.Value == "Pattern" || (definition is PdfArray { Items.Count: > 0 } array && document.Resolve(array.Items[0]) is PdfName { Value: "Pattern" })) return Space.Pattern;
        var (family, _) = ImageKit.Describe(document, definition);
        if (family is ImageFamily.Spot or ImageFamily.Lab) Left++;
        return family switch { ImageFamily.Gray => Space.Gray, ImageFamily.Rgb => Space.Rgb, ImageFamily.Cmyk => Space.Cmyk, _ => Space.Other };
    }

    private void GrayImage(PdfStream stream)
    {
        var dictionary = stream.Dictionary;
        var (family, components) = ImageKit.Describe(document, dictionary["ColorSpace"]);
        if (family is ImageFamily.Gray or ImageFamily.Unknown) return;
        int width = (int)(document.Integer(dictionary, "Width") ?? 0), height = (int)(document.Integer(dictionary, "Height") ?? 0);
        if (family is ImageFamily.Spot or ImageFamily.Lab || width < 1 || height < 1 || (long)width * height > MaxPixels || document.Resolve(dictionary["Mask"]) is PdfArray)
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
