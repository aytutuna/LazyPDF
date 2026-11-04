namespace LazyPDF.Core;

/// <summary>
/// One operator of a content stream with its operands (ISO 32000-1 7.8.2). <see cref="Start"/> and
/// <see cref="End"/> are byte positions in the data it was parsed from, from the first operand to
/// just past the operator, so an editor can cut or replace exactly this operation.
/// </summary>
public sealed class ContentOperation(string name, IReadOnlyList<PdfObject> operands, int start, int end, InlineImage? image = null)
{
    public string Operator { get; } = name;
    public IReadOnlyList<PdfObject> Operands { get; } = operands;
    public int Start { get; } = start;
    public int End { get; } = end;

    /// <summary>For <c>BI</c>: the image, whose dictionary and data are not operands. Null otherwise.</summary>
    public InlineImage? Image { get; } = image;

    /// <summary>Operand <paramref name="index"/> as a number; null when it is missing or not one.</summary>
    public double? Number(int index) => index >= 0 && index < Operands.Count && Operands[index] is PdfNumber n ? n.Value : null;

    public override string ToString() => $"{string.Join(' ', Operands)} {Operator}".TrimStart();
}

/// <summary>
/// The dictionary and data of a <c>BI ... ID ... EI</c> image (8.9.7). The dictionary keeps the
/// abbreviations it was written with; <see cref="Data"/> is the bytes between ID and EI, filters
/// still applied.
/// </summary>
public sealed class InlineImage(PdfDictionary dictionary, byte[] data)
{
    private static readonly Dictionary<string, string> Keys = new()
    {
        ["BPC"] = "BitsPerComponent", ["CS"] = "ColorSpace", ["D"] = "Decode", ["DP"] = "DecodeParms",
        ["F"] = "Filter", ["H"] = "Height", ["IM"] = "ImageMask", ["I"] = "Interpolate", ["W"] = "Width",
    };

    public PdfDictionary Dictionary { get; } = dictionary;
    public byte[] Data { get; } = data;

    /// <summary>
    /// The dictionary with full key names, the form the filters and image decoder read. Colour space
    /// names that are not device spaces are looked up with <paramref name="colorSpace"/> (the page's
    /// /ColorSpace resources); the other abbreviations are left to those readers.
    /// </summary>
    public PdfDictionary Expanded(Func<string, PdfObject?>? colorSpace = null)
    {
        var result = new PdfDictionary();
        foreach (var (key, value) in Dictionary.Entries)
        {
            string full = Keys.GetValueOrDefault(key, key);
            result[full] = full == "ColorSpace" && value is PdfName n && colorSpace?.Invoke(n.Value) is { } found ? found : value;
        }
        return result;
    }
}
