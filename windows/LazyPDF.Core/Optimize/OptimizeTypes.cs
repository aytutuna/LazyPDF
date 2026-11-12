namespace LazyPDF.Core;

public enum OptimizePreset { Small, Balanced, HighQuality }

public enum OptimizeStepKind
{
    RemoveUnreferenced,
    ObjectStreams,
    RecompressStreams,
    ConvertOldFilters,
    RemoveDuplicates,
    StripThumbnails,
    StripPieceInfo,
    StripPrivateData,
    PruneResources,
    DownsampleImages,
    BilevelImages,
    SubsetFonts,
    Grayscale,
}

/// <summary>What the optimizer does. <see cref="For"/> gives the three presets.</summary>
public sealed record OptimizeOptions
{
    public bool ObjectStreams { get; init; } = true;
    public bool RecompressStreams { get; init; } = true;
    public bool ConvertOldFilters { get; init; } = true;
    public bool RemoveDuplicates { get; init; } = true;
    public bool StripThumbnails { get; init; } = true;
    public bool StripPieceInfo { get; init; } = true;
    public bool StripPrivateData { get; init; }
    public bool PruneResources { get; init; } = true;

    /// <summary>The resolution images are brought down to; 0 leaves images alone.</summary>
    public int ImageDpi { get; init; }

    /// <summary>Only images placed at more than this many dpi are touched.</summary>
    public int ImageDpiAbove { get; init; }

    /// <summary>Quality (1 to 100) of JPEG data written when an image is downsampled or turned gray.</summary>
    public int JpegQuality { get; init; } = 75;

    /// <summary>Gray and colour images whose pixels are all within this many levels of black or white become 1-bit; negative leaves them.</summary>
    public int BilevelTolerance { get; init; } = -1;

    public bool SubsetFonts { get; init; }
    public bool Grayscale { get; init; }

    /// <summary>Encrypts the new file; null writes it open, whatever the source was.</summary>
    public PdfSecurity? Security { get; init; }

    /// <summary>First string of the new /ID, as in <see cref="PdfSaveOptions"/>.</summary>
    public byte[]? DocumentId { get; init; }

    public static OptimizeOptions For(OptimizePreset preset) => preset switch
    {
        OptimizePreset.Small => new OptimizeOptions
        {
            StripPrivateData = true, ImageDpi = 96, ImageDpiAbove = 144, JpegQuality = 50, BilevelTolerance = 24, SubsetFonts = true,
        },
        OptimizePreset.Balanced => new OptimizeOptions
        {
            ImageDpi = 150, ImageDpiAbove = 225, JpegQuality = 80, SubsetFonts = true,
        },
        _ => new OptimizeOptions
        {
            StripPieceInfo = false, ImageDpi = 300, ImageDpiAbove = 450, JpegQuality = 92, BilevelTolerance = 0,
        },
    };
}

public enum SpaceKind { Images, Fonts, Content, Forms, Annotations, Metadata, Structure, Attachments, Overhead, Unreferenced }

/// <summary>Where the bytes of a file go. The kinds add up to <see cref="FileSize"/>.</summary>
public sealed record SpaceAudit(long FileSize, IReadOnlyDictionary<SpaceKind, long> Bytes)
{
    public long Of(SpaceKind kind) => Bytes.GetValueOrDefault(kind);
}

/// <summary>The audit and the steps the options would run; the counts come with the run.</summary>
public sealed record OptimizePlan(SpaceAudit Audit, IReadOnlyList<OptimizeStepKind> Steps);

/// <summary>How many things a step changed.</summary>
public sealed record OptimizeStepResult(OptimizeStepKind Kind, int Count);

public sealed record OptimizeResult(byte[] Bytes, long SizeBefore, long SizeAfter, SpaceAudit Audit,
    IReadOnlyList<OptimizeStepResult> Steps, IReadOnlyList<string> Notes, int Dropped = 0);

public enum SanitizeItem
{
    JavaScript,
    LaunchActions,
    EmbeddedFiles,
    HiddenLayers,
    HiddenText,
    InvisibleText,
    Comments,
    FormData,
    Metadata,
    PieceInfo,
    Thumbnails,
    PreviousVersions,
    SearchIndexes,
    ExternalLinks,
    FilePaths,
    Signatures,
}

public sealed record SanitizeFinding(SanitizeItem Item, int Count);

/// <summary>What the sanitizer removes. Text in render mode 3 may be an OCR layer, so it goes only when asked.</summary>
public sealed record SanitizeOptions
{
    public bool JavaScript { get; init; } = true;
    public bool LaunchActions { get; init; } = true;
    public bool EmbeddedFiles { get; init; } = true;
    public bool HiddenLayers { get; init; } = true;
    public bool InvisibleText { get; init; }
    public bool Comments { get; init; } = true;
    public bool FormData { get; init; } = true;
    public bool Metadata { get; init; } = true;
    public bool PieceInfo { get; init; } = true;
    public bool Thumbnails { get; init; } = true;
    public bool SearchIndexes { get; init; } = true;
    public bool ExternalLinks { get; init; } = true;
    public bool FilePaths { get; init; } = true;

    /// <summary>Write the output with the input's encryption; ignored when <see cref="Security"/> is given.</summary>
    public bool KeepEncryption { get; init; } = true;

    public PdfSecurity? Security { get; init; }
    public byte[]? DocumentId { get; init; }
}

/// <summary><paramref name="Removed"/> are the findings taken out, <paramref name="Kept"/> what was found and left (an item switched off, or hidden text, which is only reported).</summary>
public sealed record SanitizeResult(byte[] Bytes, IReadOnlyList<SanitizeFinding> Removed, IReadOnlyList<SanitizeFinding> Kept, long SizeBefore, long SizeAfter);
