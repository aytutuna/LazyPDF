namespace LazyPDF.App.Tools.Export;

public enum ExportFormat
{
    Word,
    Excel,
    PowerPoint,
    Html,
    Markdown,
    Rtf,
    Text,
    Pictures,
    Images,
}

public enum PictureFormat
{
    Png,
    Jpeg,
    Tiff,
    Bmp,
}

/// <param name="Pages">0-based pages in the order wanted; null for all of them.</param>
/// <param name="FixedHtml">HTML with every line at its place on the page, instead of text that reflows.</param>
public sealed record ExportOptions(ExportFormat Format, IReadOnlyList<int>? Pages = null, bool FixedHtml = false, bool MarkdownPictures = false,
                                   PictureFormat Picture = PictureFormat.Png, int Dpi = 150, int Quality = 85,
                                   string NamePattern = "{name} page {n}", bool Replace = false)
{
    /// <summary>Pictures go into a folder; every other format is one file.</summary>
    public bool ToFolder => Format is ExportFormat.Pictures or ExportFormat.Images;

    public string Extension => Format switch
    {
        ExportFormat.Word => ".docx",
        ExportFormat.Excel => ".xlsx",
        ExportFormat.PowerPoint => ".pptx",
        ExportFormat.Html => ".html",
        ExportFormat.Markdown => ".md",
        ExportFormat.Rtf => ".rtf",
        ExportFormat.Text => ".txt",
        _ => "",
    };
}

/// <summary>What an export could not carry over.</summary>
public enum ExportGap
{
    None,
    /// <summary>The pages have no text, so nothing was written.</summary>
    NoText,
    /// <summary>The workbook has the tables only.</summary>
    OutsideTables,
    /// <summary>The workbook stops at the most sheets it holds.</summary>
    PastSheetLimit,
}

/// <param name="Files">How many files were written.</param>
/// <param name="Where">The file written, or the folder when there are several.</param>
/// <param name="Skipped">Pages the system could not draw.</param>
public sealed record ExportResult(int Files, string Where, int Skipped = 0, ExportGap Gap = ExportGap.None, int PicturesLeftOut = 0);
