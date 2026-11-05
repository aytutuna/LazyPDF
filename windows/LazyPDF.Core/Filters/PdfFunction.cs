namespace LazyPDF.Core;

/// <summary>
/// A PDF function (ISO 32000-1 7.10): sampled (type 0), exponential (2), stitching (3) or
/// PostScript calculator (4). Inputs and outputs are clipped to /Domain and /Range.
/// </summary>
public abstract partial class PdfFunction
{
    private const int MaxDepth = 8;
    private const int MaxOutputs = 64;

    public int Inputs { get; private protected init; }
    public int Outputs { get; private protected init; }

    private protected double[] Domain = [];
    private protected double[]? Range;

    /// <summary><paramref name="output"/> must hold <see cref="Outputs"/> values.</summary>
    public void Evaluate(ReadOnlySpan<double> input, Span<double> output)
    {
        Span<double> clipped = stackalloc double[Math.Min(Inputs, 32)];
        for (int i = 0; i < clipped.Length; i++)
            clipped[i] = Math.Clamp(i < input.Length ? input[i] : 0, Domain[2 * i], Domain[2 * i + 1]);
        Compute(clipped, output);
        if (Range is null) return;
        for (int i = 0; i < Outputs; i++) output[i] = Math.Clamp(output[i], Range[2 * i], Range[2 * i + 1]);
    }

    private protected abstract void Compute(ReadOnlySpan<double> input, Span<double> output);

    /// <summary>
    /// Reads a function dictionary or stream, or an array of one-output functions treated as one.
    /// <paramref name="decodeStream"/> gives a stream's data with its filters undone.
    /// </summary>
    public static PdfFunction Parse(PdfObject? function, Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream) =>
        Parse(function, resolve, decodeStream, 0, new Dictionary<PdfObject, PdfFunction>(ReferenceEqualityComparer.Instance));

    // A function that several others share is parsed once; otherwise a few small objects name each other
    // often enough to take for ever.
    private static PdfFunction Parse(PdfObject? function, Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream,
                                     int depth, Dictionary<PdfObject, PdfFunction> parsed)
    {
        if (depth > MaxDepth) throw PdfReadException.Damaged("Functions nest too deep.");
        function = resolve(function);
        if (function is not null && parsed.TryGetValue(function, out var known)) return known;
        var result = ParseOne(function, resolve, decodeStream, depth, parsed);
        if (result.Outputs > MaxOutputs) throw PdfReadException.Damaged("A function has too many outputs.");
        if (function is not null) parsed[function] = result;
        return result;
    }

    private static PdfFunction ParseOne(PdfObject? function, Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream,
                                        int depth, Dictionary<PdfObject, PdfFunction> parsed)
    {
        if (function is PdfArray array)
        {
            if (array.Items.Count is 0 or > 64) throw PdfReadException.Damaged("A function array has a bad length.");
            return new Combined([.. array.Items.Select(i => Parse(i, resolve, decodeStream, depth + 1, parsed))]);
        }
        var dictionary = function switch
        {
            PdfStream s => s.Dictionary,
            PdfDictionary d => d,
            _ => throw PdfReadException.Damaged("A function is neither a dictionary nor a stream."),
        };
        var domain = Numbers(dictionary["Domain"], resolve);
        if (domain is null || domain.Length < 2 || domain.Length % 2 != 0 || domain.Length > 64)
            throw PdfReadException.Damaged("A function has no usable /Domain.");
        if (!Ordered(domain)) throw PdfReadException.Damaged("A function's /Domain runs backwards.");
        var range = Numbers(dictionary["Range"], resolve);
        if (range is not null && range.Length % 2 != 0) range = null;
        if (range is not null && (range.Length > 2 * MaxOutputs || !Ordered(range))) throw PdfReadException.Damaged("A function has a bad /Range.");
        int type = PdfFilters.Int(resolve(dictionary["FunctionType"]), -1);
        PdfFunction made = type switch
        {
            0 => Sampled.Create(dictionary, function as PdfStream, domain, range, resolve, decodeStream),
            2 => Exponential.Create(dictionary, domain, range, resolve),
            3 => Stitching.Create(dictionary, domain, resolve, decodeStream, depth, parsed),
            4 => PostScript.Create(function as PdfStream, domain, range, decodeStream),
            _ => throw new PdfReadException(PdfReadProblem.Unsupported, $"Function type {type} is not supported."),
        };
        made.Domain = domain;
        made.Range = range is not null && range.Length >= made.Outputs * 2 ? range : null;
        return made;
    }

    /// <summary>Each (min, max) pair is in order, which Math.Clamp wants.</summary>
    internal static bool Ordered(double[] pairs)
    {
        for (int i = 0; i + 1 < pairs.Length; i += 2)
        {
            if (pairs[i] > pairs[i + 1]) return false;
        }
        return true;
    }

    internal static double[]? Numbers(PdfObject? value, Func<PdfObject?, PdfObject?> resolve)
    {
        if (resolve(value) is not PdfArray array) return null;
        var numbers = new double[array.Items.Count];
        for (int i = 0; i < numbers.Length; i++)
        {
            if (resolve(array.Items[i]) is not PdfNumber n) return null;
            numbers[i] = n.Value;
        }
        return numbers;
    }

    private static double Interpolate(double x, double x0, double x1, double y0, double y1) =>
        x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0);

    private sealed class Combined : PdfFunction
    {
        private readonly PdfFunction[] _parts;

        public Combined(PdfFunction[] parts)
        {
            _parts = parts;
            Inputs = parts[0].Inputs;
            Outputs = parts.Sum(p => p.Outputs);
            Domain = parts[0].Domain;
        }

        private protected override void Compute(ReadOnlySpan<double> input, Span<double> output)
        {
            int at = 0;
            foreach (var part in _parts)
            {
                part.Evaluate(input, output.Slice(at, part.Outputs));
                at += part.Outputs;
            }
        }
    }

    private sealed class Exponential : PdfFunction
    {
        private double[] _c0 = [], _c1 = [];
        private double _n;

        public static Exponential Create(PdfDictionary d, double[] domain, double[]? range, Func<PdfObject?, PdfObject?> resolve)
        {
            var c0 = Numbers(d["C0"], resolve) ?? [0];
            var c1 = Numbers(d["C1"], resolve) ?? [1];
            if (c0.Length != c1.Length || c0.Length > 64) throw PdfReadException.Damaged("A type 2 function has unequal /C0 and /C1.");
            return new Exponential
            {
                _c0 = c0,
                _c1 = c1,
                _n = resolve(d["N"]) is PdfNumber n ? n.Value : 1,
                Inputs = 1,
                Outputs = c0.Length,
            };
        }

        private protected override void Compute(ReadOnlySpan<double> input, Span<double> output)
        {
            double x = _n == 1 ? input[0] : Math.Pow(input[0], _n);
            for (int i = 0; i < _c0.Length; i++) output[i] = _c0[i] + x * (_c1[i] - _c0[i]);
        }
    }

    private sealed class Stitching : PdfFunction
    {
        private PdfFunction[] _functions = [];
        private double[] _bounds = [], _encode = [];

        public static Stitching Create(PdfDictionary d, double[] domain, Func<PdfObject?, PdfObject?> resolve,
                                       Func<PdfStream, byte[]> decodeStream, int depth, Dictionary<PdfObject, PdfFunction> parsed)
        {
            if (resolve(d["Functions"]) is not PdfArray list || list.Items.Count is 0 or > 256)
                throw PdfReadException.Damaged("A type 3 function has no /Functions.");
            var functions = list.Items.Select(i => Parse(i, resolve, decodeStream, depth + 1, parsed)).ToArray();
            var bounds = Numbers(d["Bounds"], resolve);
            var encode = Numbers(d["Encode"], resolve);
            if (bounds is null || bounds.Length != functions.Length - 1 || encode is null || encode.Length < functions.Length * 2)
                throw PdfReadException.Damaged("A type 3 function has bad /Bounds or /Encode.");
            if (functions.Any(f => f.Inputs != 1 || f.Outputs != functions[0].Outputs))
                throw PdfReadException.Damaged("The functions of a type 3 function do not agree.");
            return new Stitching { _functions = functions, _bounds = bounds, _encode = encode, Inputs = 1, Outputs = functions[0].Outputs };
        }

        private protected override void Compute(ReadOnlySpan<double> input, Span<double> output)
        {
            double x = input[0];
            int i = 0;
            while (i < _bounds.Length && x >= _bounds[i]) i++;
            double low = i == 0 ? Domain[0] : _bounds[i - 1];
            double high = i == _bounds.Length ? Domain[1] : _bounds[i];
            Span<double> encoded = [Interpolate(x, low, high, _encode[2 * i], _encode[2 * i + 1])];
            _functions[i].Evaluate(encoded, output);
        }
    }

    private sealed class Sampled : PdfFunction
    {
        private byte[] _data = [];
        private int[] _size = [], _stride = [];
        private int _bits;
        private double[] _encode = [], _decode = [];

        public static Sampled Create(PdfDictionary d, PdfStream? stream, double[] domain, double[]? range,
                                     Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream)
        {
            int inputs = domain.Length / 2;
            if (stream is null || range is null || range.Length < 2) throw PdfReadException.Damaged("A type 0 function needs a stream and a /Range.");
            if (inputs > 8) throw new PdfReadException(PdfReadProblem.Unsupported, "A sampled function with more than 8 inputs.");
            int outputs = range.Length / 2;
            var sizes = Numbers(d["Size"], resolve);
            int bits = PdfFilters.Int(resolve(d["BitsPerSample"]), 0);
            if (sizes is null || sizes.Length != inputs || bits is not (1 or 2 or 4 or 8 or 12 or 16 or 24 or 32))
                throw PdfReadException.Damaged("A type 0 function has bad /Size or /BitsPerSample.");
            var size = new int[inputs];
            var stride = new int[inputs];
            long total = outputs;
            for (int i = 0; i < inputs; i++)
            {
                if (sizes[i] < 1 || sizes[i] > int.MaxValue) throw PdfReadException.Damaged("A type 0 function has a bad /Size.");
                size[i] = (int)sizes[i];
                stride[i] = (int)Math.Min(total, int.MaxValue);
                if (size[i] > 8L * Array.MaxLength / bits / total) throw PdfReadException.Damaged("A type 0 function has too many samples.");
                total *= size[i];
            }
            var data = decodeStream(stream);
            if (total * bits > data.LongLength * 8) throw PdfReadException.Damaged("A type 0 function has fewer samples than /Size says.");
            var encode = Numbers(d["Encode"], resolve);
            if (encode is null || encode.Length < inputs * 2)
                encode = [.. size.SelectMany(s => new double[] { 0, s - 1 })];
            var decode = Numbers(d["Decode"], resolve);
            if (decode is null || decode.Length < outputs * 2) decode = range;
            return new Sampled { _data = data, _size = size, _stride = stride, _bits = bits, _encode = encode, _decode = decode, Inputs = inputs, Outputs = outputs };
        }

        private protected override void Compute(ReadOnlySpan<double> input, Span<double> output)
        {
            Span<int> low = stackalloc int[Inputs];
            Span<double> fraction = stackalloc double[Inputs];
            for (int i = 0; i < Inputs; i++)
            {
                double e = Interpolate(input[i], Domain[2 * i], Domain[2 * i + 1], _encode[2 * i], _encode[2 * i + 1]);
                // A NaN does not clamp and leaves a fraction that weighs the corner past the last sample.
                e = double.IsNaN(e) ? 0 : Math.Clamp(e, 0, _size[i] - 1);
                low[i] = Math.Min((int)e, Math.Max(_size[i] - 2, 0));
                fraction[i] = e - low[i];
            }
            output.Slice(0, Outputs).Clear();
            double max = _bits == 32 ? uint.MaxValue : (1L << _bits) - 1;
            for (int corner = 0; corner < 1 << Inputs; corner++)
            {
                double weight = 1;
                long index = 0;
                for (int i = 0; i < Inputs; i++)
                {
                    bool upper = (corner >> i & 1) != 0;
                    weight *= upper ? fraction[i] : 1 - fraction[i];
                    index += (long)(low[i] + (upper ? 1 : 0)) * _stride[i];
                }
                if (weight == 0) continue;
                for (int j = 0; j < Outputs; j++) output[j] += weight * Sample(index + j);
            }
            for (int j = 0; j < Outputs; j++)
                output[j] = Interpolate(output[j], 0, max, _decode[2 * j], _decode[2 * j + 1]);
        }

        private double Sample(long index)
        {
            long bit = index * _bits;
            int at = (int)(bit >> 3);
            switch (_bits)
            {
                case 8: return _data[at];
                case 16: return _data[at] << 8 | _data[at + 1];
                case 24: return _data[at] << 16 | _data[at + 1] << 8 | _data[at + 2];
                case 32: return (uint)(_data[at] << 24 | _data[at + 1] << 16 | _data[at + 2] << 8 | _data[at + 3]);
                case 12:
                    return (bit & 7) == 0 ? _data[at] << 4 | _data[at + 1] >> 4 : (_data[at] & 15) << 8 | _data[at + 1];
                default:
                    return _data[at] >> (8 - _bits - (int)(bit & 7)) & ((1 << _bits) - 1);
            }
        }
    }
}
