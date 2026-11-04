namespace LazyPDF.Core;

/// <summary>A colour space (ISO 32000-1 8.6) reduced to what turning samples into sRGB needs.</summary>
internal abstract class SampleColorSpace
{
    private const int MaxDepth = 8;

    public abstract int Components { get; }

    public virtual double Min(int component) => 0;

    public virtual double Max(int component) => 1;

    public abstract void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb);

    public static SampleColorSpace Parse(PdfObject? space, Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream, int depth = 0)
    {
        if (depth > MaxDepth) throw PdfReadException.Damaged("Colour spaces nest too deep.");
        space = resolve(space);
        if (space is PdfName single) return Simple(single.Value);
        if (space is not PdfArray { Items.Count: > 0 } array || resolve(array.Items[0]) is not PdfName family)
            throw PdfReadException.Damaged("A colour space is neither a name nor an array.");
        PdfObject? Item(int i) => i < array.Items.Count ? resolve(array.Items[i]) : null;
        switch (family.Value)
        {
            case "ICCBased":
                var profile = (Item(1) as PdfStream)?.Dictionary ?? throw PdfReadException.Damaged("An ICCBased space has no profile stream.");
                switch (PdfFilters.Int(resolve(profile["N"]), 0))
                {
                    case 1: return new Gray();
                    case 3: return new Rgb();
                    case 4: return new Cmyk();
                }
                if (profile["Alternate"] is { } alternate) return Parse(alternate, resolve, decodeStream, depth + 1);
                throw PdfReadException.Damaged("An ICCBased space has no usable /N.");
            case "CalGray": return new Gray();
            case "CalRGB": return CalRgb.Create(Item(1) as PdfDictionary, resolve);
            case "Lab": return Lab.Create(Item(1) as PdfDictionary, resolve);
            case "Indexed" or "I":
                return Indexed.Create(Item(1), PdfFilters.Int(Item(2), 0), Item(3), resolve, decodeStream, depth);
            case "Separation" or "DeviceN":
                int count = family.Value == "Separation" ? 1 : (Item(1) as PdfArray)?.Items.Count ?? 0;
                if (count is < 1 or > 32) throw PdfReadException.Damaged("A tint space has a bad number of colorants.");
                var alt = Parse(Item(2), resolve, decodeStream, depth + 1);
                var function = PdfFunction.Parse(Item(3), resolve, decodeStream);
                if (function.Inputs != count || function.Outputs < alt.Components)
                    throw PdfReadException.Damaged("A tint transform does not fit its colour space.");
                return new Tint(count, alt, function);
            case "Pattern":
                throw new PdfReadException(PdfReadProblem.Unsupported, "A pattern colour space on an image.");
            default:
                if (array.Items.Count == 1) return Simple(family.Value);
                throw new PdfReadException(PdfReadProblem.Unsupported, $"The /{family.Value} colour space is not supported.");
        }
    }

    private static SampleColorSpace Simple(string name) => name switch
    {
        "DeviceGray" or "G" or "CalGray" => new Gray(),
        "DeviceRGB" or "RGB" or "CalRGB" => new Rgb(),
        "DeviceCMYK" or "CMYK" => new Cmyk(),
        _ => throw new PdfReadException(PdfReadProblem.Unsupported, $"The /{name} colour space is not supported."),
    };

    internal static byte Byte(double v) => (byte)(Math.Clamp(v, 0, 1) * 255 + 0.5);

    internal sealed class Gray : SampleColorSpace
    {
        public override int Components => 1;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb) => rgb.Fill(Byte(c[0]));
    }

    internal sealed class Rgb : SampleColorSpace
    {
        public override int Components => 3;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            rgb[0] = Byte(c[0]);
            rgb[1] = Byte(c[1]);
            rgb[2] = Byte(c[2]);
        }
    }

    /// <summary>The plain conversion, without a profile: each channel is what the ink leaves, (1 - c)(1 - k).</summary>
    internal sealed class Cmyk : SampleColorSpace
    {
        public override int Components => 4;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            double k = 1 - Math.Clamp(c[3], 0, 1);
            rgb[0] = Byte((1 - Math.Clamp(c[0], 0, 1)) * k);
            rgb[1] = Byte((1 - Math.Clamp(c[1], 0, 1)) * k);
            rgb[2] = Byte((1 - Math.Clamp(c[2], 0, 1)) * k);
        }
    }

    internal sealed class CalRgb : SampleColorSpace
    {
        private double[] _gamma = [1, 1, 1], _matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1], _white = [0.9505, 1, 1.089];

        public static CalRgb Create(PdfDictionary? d, Func<PdfObject?, PdfObject?> resolve)
        {
            var result = new CalRgb();
            if (d is null) return result;
            if (PdfFunction.Numbers(d["Gamma"], resolve) is { Length: 3 } gamma) result._gamma = gamma;
            if (PdfFunction.Numbers(d["Matrix"], resolve) is { Length: 9 } matrix) result._matrix = matrix;
            if (PdfFunction.Numbers(d["WhitePoint"], resolve) is { Length: 3 } white && white[0] > 0 && white[1] > 0 && white[2] > 0) result._white = white;
            return result;
        }

        public override int Components => 3;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            double a = Math.Pow(Math.Clamp(c[0], 0, 1), _gamma[0]);
            double b = Math.Pow(Math.Clamp(c[1], 0, 1), _gamma[1]);
            double g = Math.Pow(Math.Clamp(c[2], 0, 1), _gamma[2]);
            Srgb(_matrix[0] * a + _matrix[3] * b + _matrix[6] * g,
                 _matrix[1] * a + _matrix[4] * b + _matrix[7] * g,
                 _matrix[2] * a + _matrix[5] * b + _matrix[8] * g, _white, rgb);
        }
    }

    internal sealed class Lab : SampleColorSpace
    {
        private double[] _range = [-100, 100, -100, 100], _white = [0.9642, 1, 0.8249];

        public static Lab Create(PdfDictionary? d, Func<PdfObject?, PdfObject?> resolve)
        {
            var result = new Lab();
            if (d is null) return result;
            if (PdfFunction.Numbers(d["Range"], resolve) is { Length: 4 } range && PdfFunction.Ordered(range)) result._range = range;
            if (PdfFunction.Numbers(d["WhitePoint"], resolve) is { Length: 3 } white && white[0] > 0 && white[1] > 0 && white[2] > 0) result._white = white;
            return result;
        }

        public override int Components => 3;

        public override double Min(int component) => component == 0 ? 0 : _range[(component - 1) * 2];

        public override double Max(int component) => component == 0 ? 100 : _range[(component - 1) * 2 + 1];

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            double m = (Math.Clamp(c[0], 0, 100) + 16) / 116;
            double l = m + Math.Clamp(c[1], _range[0], _range[1]) / 500;
            double n = m - Math.Clamp(c[2], _range[2], _range[3]) / 200;
            Srgb(_white[0] * Inverse(l), _white[1] * Inverse(m), _white[2] * Inverse(n), _white, rgb);
        }

        private static double Inverse(double x) => x >= 6.0 / 29 ? x * x * x : 108.0 / 841 * (x - 4.0 / 29);
    }

    internal sealed class Indexed : SampleColorSpace
    {
        private byte[] _palette = [];

        public int HighValue { get; private set; }

        public static Indexed Create(PdfObject? baseSpace, int high, PdfObject? lookup, Func<PdfObject?, PdfObject?> resolve,
                                     Func<PdfStream, byte[]> decodeStream, int depth)
        {
            var space = Parse(baseSpace, resolve, decodeStream, depth + 1);
            if (space is Indexed) throw PdfReadException.Damaged("An Indexed space is based on another.");
            high = Math.Clamp(high, 0, 255);
            byte[] table = lookup switch
            {
                PdfString s => s.Bytes,
                PdfStream stream => decodeStream(stream),
                _ => throw PdfReadException.Damaged("An Indexed space has no lookup table."),
            };
            int n = space.Components;
            var palette = new byte[(high + 1) * 3];
            Span<double> comps = stackalloc double[n];
            for (int i = 0; i <= high; i++)
            {
                for (int j = 0; j < n; j++)
                {
                    int at = i * n + j;
                    double unit = at < table.Length ? table[at] / 255.0 : 0;
                    comps[j] = space.Min(j) + unit * (space.Max(j) - space.Min(j));
                }
                space.ToRgb(comps, palette.AsSpan(i * 3, 3));
            }
            return new Indexed { _palette = palette, HighValue = high };
        }

        public override int Components => 1;

        public override double Max(int component) => HighValue;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            int index = Math.Clamp((int)(c[0] + 0.5), 0, HighValue);
            _palette.AsSpan(index * 3, 3).CopyTo(rgb);
        }
    }

    /// <summary>Separation and DeviceN: the tint transform gives the alternate space's values.</summary>
    internal sealed class Tint(int components, SampleColorSpace alternate, PdfFunction function) : SampleColorSpace
    {
        public override int Components => components;

        public override void ToRgb(ReadOnlySpan<double> c, Span<byte> rgb)
        {
            Span<double> values = stackalloc double[function.Outputs];
            function.Evaluate(c, values);
            for (int i = 0; i < alternate.Components; i++) values[i] = Math.Clamp(values[i], alternate.Min(i), alternate.Max(i));
            alternate.ToRgb(values, rgb);
        }
    }

    /// <summary>XYZ relative to <paramref name="white"/> to sRGB: the white is scaled to D65, which is crude next to a proper adaptation and enough for a preview.</summary>
    private static void Srgb(double x, double y, double z, double[] white, Span<byte> rgb)
    {
        x *= 0.9505 / white[0];
        y /= white[1];
        z *= 1.089 / white[2];
        rgb[0] = Byte(Encode(3.2406 * x - 1.5372 * y - 0.4986 * z));
        rgb[1] = Byte(Encode(-0.9689 * x + 1.8758 * y + 0.0415 * z));
        rgb[2] = Byte(Encode(0.0557 * x - 0.2040 * y + 1.0570 * z));
    }

    private static double Encode(double linear)
    {
        linear = Math.Clamp(linear, 0, 1);
        return linear <= 0.0031308 ? 12.92 * linear : 1.055 * Math.Pow(linear, 1 / 2.4) - 0.055;
    }
}
