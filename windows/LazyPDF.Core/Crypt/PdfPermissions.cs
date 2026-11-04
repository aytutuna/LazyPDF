namespace LazyPDF.Core;

/// <summary>What the document's /P value lets a reader do (ISO 32000-1 7.6.3.2, table 22). A request to the reader, not a lock.</summary>
[Flags]
public enum PdfPermissions
{
    None = 0,
    /// <summary>Print, at low quality when <see cref="PrintHighQuality"/> is missing.</summary>
    Print = 1 << 2,
    Modify = 1 << 3,
    Copy = 1 << 4,
    Annotate = 1 << 5,
    FillForms = 1 << 8,
    ExtractForAccessibility = 1 << 9,
    Assemble = 1 << 10,
    PrintHighQuality = 1 << 11,
    All = Print | Modify | Copy | Annotate | FillForms | ExtractForAccessibility | Assemble | PrintHighQuality,
}

/// <summary>The cipher a new file is encrypted with. The first member is the default.</summary>
public enum PdfCryptStrength
{
    /// <summary>V 5, R 6 (ISO 32000-2).</summary>
    Aes256,
    /// <summary>V 4, R 4, the AESV2 crypt filter.</summary>
    Aes128,
}
