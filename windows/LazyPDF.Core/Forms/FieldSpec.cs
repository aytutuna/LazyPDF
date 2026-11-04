namespace LazyPDF.Core;

/// <summary>
/// A field to add with <see cref="PdfForm.AddField"/>: where it goes and how it looks. Colours are 1, 3 or
/// 4 numbers from 0 to 1; a null colour paints nothing. Flags that name the kind (radio, push button,
/// combo) are set by <see cref="Kind"/>.
/// </summary>
public sealed record FieldSpec(FieldKind Kind, string Name, int PageIndex, PdfRect Rect)
{
    public string? Value { get; init; }
    public string? DefaultValue { get; init; }

    /// <summary>The choices of a combo or list box.</summary>
    public IReadOnlyList<FieldOption>? Options { get; init; }

    /// <summary>Required, read only, multiline, password, comb, multi-select, editable combo and the like.</summary>
    public FieldFlags Flags { get; init; }
    public int MaxLength { get; init; }
    public string? Tooltip { get; init; }

    /// <summary>The name of a font in /DR; Helv is added when the form has none.</summary>
    public string Font { get; init; } = "Helv";

    /// <summary>In points; 0 fits the text to the field.</summary>
    public double FontSize { get; init; }
    public double[] TextColor { get; init; } = [0];
    public double[]? BorderColor { get; init; } = [0];
    public double[]? Background { get; init; }
    public double BorderWidth { get; init; } = 1;
    public BorderStyle BorderStyle { get; init; }

    /// <summary>0 left, 1 centred, 2 right.</summary>
    public int Alignment { get; init; }

    /// <summary>Turns the widget by 0, 90, 180 or 270 degrees (/MK /R).</summary>
    public int Rotation { get; init; }

    /// <summary>The caption of a push button, or the mark of a check box or radio button (a ZapfDingbats character: 4 check, 8 cross, l circle, n square, u diamond, H star).</summary>
    public string? Caption { get; init; }

    /// <summary>What a check box or the first radio button exports; "Yes" and "Choice1" when null.</summary>
    public string? ExportValue { get; init; }
}
