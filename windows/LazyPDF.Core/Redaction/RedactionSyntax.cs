namespace LazyPDF.Core;

/// <summary>
/// The operators of ISO 32000-1 Annex A with the operands each takes, and nothing else. A viewer is free to
/// read an operator with other operands, or one it does not know, in its own way, and what it draws from them
/// is never looked at, so content that strays from this table is content that is not understood.
/// </summary>
internal static class RedactionSyntax
{
    private const double MaxMove = 1 << 22;

    // n number, s string, N name, a array, d name or dictionary.
    private static readonly Dictionary<string, string> Signatures = Build(
        ("", "b B b* B* f F f* h n s S q Q BT ET T* W W* EMC"),
        ("n", "w J j M i Tc Tw Tz TL Tr Ts g G"),
        ("nn", "m l Td TD d0"),
        ("nnn", "rg RG"),
        ("nnnn", "v y re k K"),
        ("nnnnnn", "c cm Tm d1"),
        ("N", "ri gs Do sh cs CS BMC MP"),
        ("Nn", "Tf"),
        ("Nd", "BDC DP"),
        ("an", "d"),
        ("s", "Tj '"),
        ("nns", "\""),
        ("a", "TJ"));

    // What a Type 3 glyph procedure may hold: shapes, colours and the bitmaps of a bitmap font (9.6.5).
    private static readonly HashSet<string> Glyph = new("d0 d1 q Q cm w J j M d i ri m l c v y h re S s f F f* B B* b b* n W W* g G rg RG k K BI".Split(' '));

    private static Dictionary<string, string> Build(params (string Signature, string Operators)[] groups) =>
        groups.SelectMany(g => g.Operators.Split(' ').Select(o => (Name: o, g.Signature))).ToDictionary(o => o.Name, o => o.Signature);

    /// <summary>Colour spaces a page uses without naming them (8.6.5.6).</summary>
    public static readonly (string Category, string Name)[] Defaults = [("ColorSpace", "DefaultGray"), ("ColorSpace", "DefaultRGB"), ("ColorSpace", "DefaultCMYK")];

    /// <summary>Whether <paramref name="key"/> is absent or holds exactly six numbers (8.3.3): any other array is read as the identity by one viewer and cut short by another.</summary>
    public static bool IsMatrix(PdfDocument document, PdfDictionary dictionary, string key) =>
        !dictionary.ContainsKey(key) || document.Resolve(dictionary[key]) is PdfArray { Items.Count: 6 } array && array.Items.All(i => document.Resolve(i) is PdfNumber);

    public static bool InGlyph(string name) => Glyph.Contains(name);

    public static bool Knows(string name) => Signatures.ContainsKey(name) || name is "sc" or "scn" or "SC" or "SCN" or "BI";

    /// <summary>Whether the bytes are whole tokens, see <see cref="RedactionLexer"/>; <paramref name="breaks"/> are the offsets where content streams were joined.</summary>
    public static bool Whole(byte[] data, IReadOnlyList<ContentOperation> operations, IReadOnlyList<int>? breaks = null) =>
        RedactionLexer.Whole(data, operations.Where(o => o.Operator == "BI").ToDictionary(o => o.Start, o => o.End), breaks ?? []);

    public static bool Valid(ContentOperation op)
    {
        if (op.Operator == "BI") return op.Operands.Count == 0 && op.Image is not null;
        if (op.Operator is "sc" or "scn" or "SC" or "SCN")
        {
            // Only scn and SCN take a pattern name (8.6.8).
            int numbers = op.Operands.Count - (op.Operator is "scn" or "SCN" && op.Operands.Count > 0 && op.Operands[^1] is PdfName ? 1 : 0);
            return op.Operands.Count > 0 && op.Operands.Take(numbers).All(o => o is PdfNumber);
        }
        if (!Signatures.TryGetValue(op.Operator, out string? signature) || signature.Length != op.Operands.Count) return false;
        for (int i = 0; i < signature.Length; i++)
        {
            var operand = op.Operands[i];
            bool fits = signature[i] switch
            {
                'n' => operand is PdfNumber,
                's' => operand is PdfString,
                'N' => operand is PdfName,
                'd' => operand is PdfName or PdfDictionary,
                _ => operand is PdfArray,
            };
            if (!fits) return false;
        }
        return op.Operator switch
        {
            "cm" or "Tm" => Reachable(op.Operands.Skip(4)),
            "Td" or "TD" => Reachable(op.Operands),
            "TJ" => ((PdfArray)op.Operands[0]).Items.All(i => i is PdfNumber or PdfString),
            "d" => ((PdfArray)op.Operands[0]).Items.All(i => i is PdfNumber),
            _ => true,
        };
    }

    // The scan adds up moves in double and a viewer in 32-bit floats, which hold integers exactly only up to 2^24. Two large moves that cancel
    // land in different places, so a move that large is not understood. A scale may be as large as it likes: it has no sum to lose.
    private static bool Reachable(IEnumerable<PdfObject> moves) => moves.All(m => m is PdfNumber { Value: > -MaxMove and < MaxMove });

    /// <summary>The resources an operation names, as (category, name).</summary>
    public static IEnumerable<(string Category, string Name)> Names(ContentOperation op)
    {
        if (op.Operands.Count < (op.Operator is "BDC" or "DP" ? 2 : 1) && op.Operator != "BI") yield break;
        PdfObject? operand = null;
        string? category = null;
        switch (op.Operator)
        {
            case "Do": (category, operand) = ("XObject", op.Operands[0]); break;
            case "gs": (category, operand) = ("ExtGState", op.Operands[0]); break;
            case "Tf": (category, operand) = ("Font", op.Operands[0]); break;
            case "sh": (category, operand) = ("Shading", op.Operands[0]); break;
            case "cs" or "CS" when op.Operands[0] is PdfName { Value: not ("DeviceGray" or "DeviceRGB" or "DeviceCMYK" or "Pattern") }:
                (category, operand) = ("ColorSpace", op.Operands[0]);
                break;
            case "sc" or "scn" or "SC" or "SCN": (category, operand) = ("Pattern", op.Operands[^1]); break;
            case "BDC" or "DP": (category, operand) = ("Properties", op.Operands[1]); break;
            case "BI" when op.Image is { } image && Space(image) is { } space: (category, operand) = ("ColorSpace", space); break;
        }
        if (category is not null && operand is PdfName name) yield return (category, name.Value);
    }

    /// <summary>The colour space an inline image names, when it is not one of the device spaces that have abbreviations.</summary>
    private static PdfName? Space(InlineImage image) =>
        (image.Dictionary["CS"] ?? image.Dictionary["ColorSpace"]) is PdfName { Value: not ("G" or "RGB" or "CMYK" or "DeviceGray" or "DeviceRGB" or "DeviceCMYK") } name ? name : null;

    /// <summary>
    /// Whether the end of an inline image is the same in every reading. A filter is decoded to find the end, and the
    /// parser does not decode, so only unfiltered data is accepted: a viewer counts the samples, and the data must be as
    /// long as the dimensions say, with nothing but white space between it and the EI.
    /// </summary>
    public static bool Fits(PdfDocument document, ContentOperation op, byte[] data, Func<string, PdfObject?> space)
    {
        var image = op.Image!;
        if (op.End < 2 || data[op.End - 2] != 'E' || data[op.End - 1] != 'I') return false;
        var d = image.Dictionary;
        if (d.ContainsKey("F") || d.ContainsKey("Filter")) return false;
        if ((d["W"] ?? d["Width"]) is not PdfNumber { Value: > 0 and < 1e6 } width || (d["H"] ?? d["Height"]) is not PdfNumber { Value: > 0 and < 1e6 } height) return false;
        int bits = 1, parts = 1;
        if ((d["IM"] ?? d["ImageMask"]) is not PdfBoolean { Value: true })
        {
            if ((d["BPC"] ?? d["BitsPerComponent"]) is not PdfNumber { Value: > 0 and <= 16 } depth) return false;
            bits = (int)depth.Value;
            parts = Components(document, d["CS"] ?? d["ColorSpace"], space, 0);
        }
        long expected = ((long)width.Value * parts * bits + 7) / 8 * (long)height.Value;
        // A reader that looks for EI ends the image at one inside the data, whatever the dimensions say.
        return parts > 0 && image.Data.Length >= expected && image.Data.Length <= expected + 2 && image.Data[(int)expected..].All(b => b is 0 or 9 or 10 or 12 or 13 or 32)
            && image.Data.AsSpan().IndexOf("EI"u8) < 0;
    }

    private static int Components(PdfDocument document, PdfObject? space, Func<string, PdfObject?> named, int depth)
    {
        if (depth > 3) return 0;
        switch (document.Resolve(space))
        {
            case PdfName { Value: "G" or "DeviceGray" }: return 1;
            case PdfName { Value: "RGB" or "DeviceRGB" }: return 3;
            case PdfName { Value: "CMYK" or "DeviceCMYK" }: return 4;
            case PdfName name:
                return named(name.Value) is { } found ? Components(document, found, named, depth + 1) : 0;
            case PdfArray { Items: [var first, ..] and var items }:
                return document.Resolve(first) is not PdfName kind ? 0 : kind.Value switch
                {
                    "I" or "Indexed" or "CalGray" or "Separation" => 1,
                    "CalRGB" or "Lab" => 3,
                    "ICCBased" when items.Count > 1 && document.Resolve(items[1]) is PdfStream icc => (int)(document.Integer(icc.Dictionary, "N") ?? 0),
                    "DeviceN" when items.Count > 1 && document.Resolve(items[1]) is PdfArray names => names.Items.Count,
                    _ => 0,
                };
            default:
                return 0;
        }
    }
}
