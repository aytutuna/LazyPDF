using System.Text.Json.Serialization;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Export;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Batch;

public enum BatchStepKind
{
    Ocr,
    Compress,
    Clean,
    Watermark,
    Bates,
    PageNumbers,
    PdfA,
    Rotate,
    Protect,
    ExportPictures,
}

public enum BatchPages
{
    All,
    Odd,
    Even,
}

public enum BatesPlace
{
    FooterRight,
    FooterCenter,
    FooterLeft,
    HeaderRight,
    HeaderCenter,
    HeaderLeft,
}

/// <summary>One step and the settings it uses; the settings of the other kinds are left alone.</summary>
public sealed class BatchStep
{
    public BatchStepKind Kind { get; set; }

    /// <summary>The language tag of Ocr, the text of Watermark, the prefix of Bates, the format of PageNumbers.</summary>
    public string Text { get; set; } = "";

    public OptimizePreset Preset { get; set; } = OptimizePreset.Balanced;

    public PdfALevel Level { get; set; } = PdfALevel.A2b;

    public int Digits { get; set; } = 6;

    /// <summary>The number the next file starts at; a run moves it on, so the numbers go on from one file to the next.</summary>
    public long Start { get; set; } = 1;

    public string Suffix { get; set; } = "";

    public BatesPlace Place { get; set; }

    public int Opacity { get; set; } = 30;

    /// <summary>Degrees counter-clockwise.</summary>
    public int Angle { get; set; }

    /// <summary>The width of the watermark as a percentage of the page.</summary>
    public int Size { get; set; } = 60;

    /// <summary>The size of the page numbers in points.</summary>
    public int FontSize { get; set; } = 10;

    public StampAnchor Anchor { get; set; } = StampAnchor.Center;

    /// <summary>Clockwise degrees of Rotate: 90, 180 or 270.</summary>
    public int Turn { get; set; } = 90;

    public BatchPages Pages { get; set; }

    public PictureFormat Picture { get; set; } = PictureFormat.Png;

    public int Dpi { get; set; } = 150;

    public int Quality { get; set; } = 85;

    public bool KeepComments { get; set; }

    public bool KeepForms { get; set; }

    public bool KeepLinks { get; set; }

    public bool KeepAttachments { get; set; }

    /// <summary>The password of Protect. Kept in memory only: it is left out of the saved set and asked for again.</summary>
    [JsonIgnore]
    public string Password { get; set; } = "";

    public const string PageNumberText = "Page {page} of {pages}";

    public BatchStep Copy() => (BatchStep)MemberwiseClone();

    public static BatchStep Of(BatchStepKind kind) => new()
    {
        Kind = kind,
        Text = kind switch
        {
            BatchStepKind.Ocr => OcrLanguageState.Read().Preferred()?.Tag ?? "en-US",
            BatchStepKind.PageNumbers => PageNumberText,
            _ => "",
        },
        KeepComments = kind == BatchStepKind.Clean,
        KeepForms = kind == BatchStepKind.Clean,
        KeepLinks = kind == BatchStepKind.Clean,
    };
}

/// <summary>A named list of steps with where the results go and what to call them.</summary>
public sealed class BatchSet
{
    public string Name { get; set; } = "";

    public List<BatchStep> Steps { get; set; } = [];

    public string OutputFolder { get; set; } = "";

    /// <summary>The file name of a result: {name}, {n} for the place in the run and {date} or {date:format}.</summary>
    public string NameTemplate { get; set; } = "{name}";

    public string WatchFolder { get; set; } = "";

    public bool StopOnError { get; set; }

    /// <summary>A copy that later edits to the steps do not reach.</summary>
    public BatchSet Copy() => new()
    {
        Name = Name,
        Steps = [.. Steps.Select(s => s.Copy())],
        OutputFolder = OutputFolder,
        NameTemplate = NameTemplate,
        WatchFolder = WatchFolder,
        StopOnError = StopOnError,
    };
}

public sealed class BatchSets
{
    public List<BatchSet> Sets { get; set; } = [];
}

/// <summary>batch-sets.json in %APPDATA%\Lazy PDF: the sets the person saved.</summary>
internal sealed class BatchSetStore(string? directory = null)
{
    private readonly string _path = Path.Combine(directory ?? StoreFiles.DefaultDirectory, "batch-sets.json");

    public IReadOnlyList<BatchSet> Load() => StoreFiles.Load<BatchSets>(_path)?.Sets.Where(s => s.Name.Length > 0).ToList() ?? [];

    public void Save(BatchSet set)
    {
        var sets = Load().Where(s => !string.Equals(s.Name, set.Name, StringComparison.CurrentCultureIgnoreCase)).ToList();
        sets.Add(set);
        StoreFiles.Write(new BatchSets { Sets = sets }, _path);
    }

    public void Delete(string name) =>
        StoreFiles.Write(new BatchSets { Sets = [.. Load().Where(s => !string.Equals(s.Name, name, StringComparison.CurrentCultureIgnoreCase))] }, _path);
}
