namespace LazyPDF.Core;

public enum FieldKind
{
    Text,
    CheckBox,
    Radio,
    PushButton,
    ComboBox,
    ListBox,
    Signature,
}

/// <summary>The /Ff bits (ISO 32000-1 12.7.3.1, tables 221, 226, 228 and 230).</summary>
[Flags]
public enum FieldFlags
{
    None = 0,
    ReadOnly = 1,
    Required = 1 << 1,
    NoExport = 1 << 2,
    Multiline = 1 << 12,
    Password = 1 << 13,
    NoToggleToOff = 1 << 14,
    Radio = 1 << 15,
    PushButton = 1 << 16,
    Combo = 1 << 17,
    Edit = 1 << 18,
    Sort = 1 << 19,
    FileSelect = 1 << 20,
    MultiSelect = 1 << 21,
    DoNotSpellCheck = 1 << 22,
    DoNotScroll = 1 << 23,
    Comb = 1 << 24,
    /// <summary>Rich text for a text field, radios in unison for a radio group: the same bit.</summary>
    RichText = 1 << 25,
    CommitOnSelectionChange = 1 << 26,
}

/// <summary>An /Opt entry: the value stored and the text shown.</summary>
public sealed record FieldOption(string Export, string Display)
{
    public FieldOption(string both) : this(both, both) { }
}

/// <summary>The page /Tabs entry (ISO 32000-1 12.5.2): the order Tab visits the widgets of a page.</summary>
public enum TabOrder
{
    /// <summary>No /Tabs entry: the order of /Annots.</summary>
    Annotations,
    Row,
    Column,
    Structure,
}

public enum XfaKind
{
    None,
    /// <summary>An XFA form with an AcroForm behind it, which can be filled through the AcroForm.</summary>
    Static,
    /// <summary>An XFA form that exists only as XFA; there is nothing here to fill.</summary>
    Dynamic,
}

/// <summary>One field read from the form: the merged field and widget entries, with inherited values resolved.</summary>
public sealed class FormField
{
    internal FormField(PdfDictionary dictionary, PdfReference? reference, string name, string partialName, FieldKind kind, FieldFlags flags)
    {
        Dictionary = dictionary;
        Reference = reference;
        Name = name;
        PartialName = partialName;
        Kind = kind;
        Flags = flags;
    }

    /// <summary>The terminal field dictionary, live; a merged field and widget is also its widget's dictionary.</summary>
    public PdfDictionary Dictionary { get; }
    public PdfReference? Reference { get; }

    /// <summary>The fully qualified name: the partial names from the root, joined by periods.</summary>
    public string Name { get; }
    public string PartialName { get; }
    public FieldKind Kind { get; }
    public FieldFlags Flags { get; }

    /// <summary>
    /// The value as text. For a check box or radio group it is the export value of the chosen button,
    /// or "Off"; for a list with several choices the first one (see <see cref="Selected"/>); null when none is set.
    /// </summary>
    public string? Value { get; internal set; }
    public IReadOnlyList<string> Selected { get; internal init; } = [];
    public string? DefaultValue { get; internal init; }
    public string? DefaultAppearance { get; internal init; }
    public int Alignment { get; internal init; }

    /// <summary>/MaxLen, 0 when there is none.</summary>
    public int MaxLength { get; internal init; }
    public IReadOnlyList<FieldOption> Options { get; internal init; } = [];
    public string? Tooltip { get; internal init; }
    public IReadOnlyList<FormWidget> Widgets { get; internal set; } = [];

    /// <summary>The widget is on a page but its field is not reachable from /AcroForm /Fields.</summary>
    public bool IsOrphan { get; internal init; }

    public bool IsChecked => Kind is FieldKind.CheckBox or FieldKind.Radio && Value is { } v && v != "Off";

    /// <summary>A signature field that holds a signature (/V is set). Nothing here checks it.</summary>
    public bool IsSigned => Kind == FieldKind.Signature && Dictionary["V"] is not null;

    public bool Has(FieldFlags flag) => (Flags & flag) == flag;
}

/// <summary>A widget annotation of a field.</summary>
public sealed class FormWidget
{
    internal FormWidget(PdfDictionary dictionary, PdfReference? reference, int pageIndex, PdfRect rect, string? onState, string? export)
    {
        Dictionary = dictionary;
        Reference = reference;
        PageIndex = pageIndex;
        Rect = rect;
        OnState = onState;
        Export = export;
    }

    public PdfDictionary Dictionary { get; }
    public PdfReference? Reference { get; }

    /// <summary>The page index, -1 for a widget no page lists.</summary>
    public int PageIndex { get; }
    public PdfRect Rect { get; }

    /// <summary>The name of the appearance state that means "on" (check boxes and radios), null without one.</summary>
    public string? OnState { get; }

    /// <summary>The value this button stands for: the /Opt text when the field has one, else the state name.</summary>
    public string? Export { get; }
    public bool IsOn { get; internal init; }
    public FormField Field { get; internal set; } = null!;
}

/// <summary>Which widgets <see cref="PdfForm.SetValues"/> filled and what it could not place.</summary>
/// <param name="Filled">Fields given a value (a name shared by several fields counts each).</param>
/// <param name="UnknownFields">Names no field has.</param>
/// <param name="Rejected">Names whose value does not fit the field: an unknown radio choice, a button, a signature.</param>
/// <param name="Calculated">Fields the calculation order changed afterwards.</param>
/// <param name="NotRun">Scripts that were not run because they are not built-in functions.</param>
public sealed record FormFillResult(int Filled, IReadOnlyList<string> UnknownFields, IReadOnlyList<string> Rejected, int Calculated, IReadOnlyList<FormScript> NotRun);

/// <summary>The font name (a /DR name such as Helv), size in points (0 fits the text to the field) and colour a field's /DA gives.</summary>
public sealed record TextLook(string Font, double Size, double[] Color);

public enum ButtonActionKind
{
    None,
    OpenLink,
    Reset,
    Submit,
    Show,
    Hide,

    /// <summary>An action this layer does not write: a script, a page jump and the like. Reading gives it; setting it is refused.</summary>
    Other,
}

/// <summary>What a push button does when it is clicked. <see cref="Target"/> is the address of a link or a submit, and the full name of the field a Show or Hide acts on.</summary>
public sealed record ButtonAction(ButtonActionKind Kind, string? Target = null);
