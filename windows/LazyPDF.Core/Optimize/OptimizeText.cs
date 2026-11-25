namespace LazyPDF.Core;

/// <summary>User-visible words of the optimizer and the sanitizer.</summary>
public static class OptimizeText
{
    public static string StepName(OptimizeStepKind kind) => kind switch
    {
        OptimizeStepKind.RemoveUnreferenced => Loc.T("Remove unused objects"),
        OptimizeStepKind.ObjectStreams => Loc.T("Pack objects"),
        OptimizeStepKind.RecompressStreams => Loc.T("Recompress streams"),
        OptimizeStepKind.ConvertOldFilters => Loc.T("Replace old filters"),
        OptimizeStepKind.RemoveDuplicates => Loc.T("Merge duplicates"),
        OptimizeStepKind.StripThumbnails => Loc.T("Remove thumbnails"),
        OptimizeStepKind.StripPieceInfo => Loc.T("Remove application data"),
        OptimizeStepKind.StripPrivateData => Loc.T("Remove private keys"),
        OptimizeStepKind.PruneResources => Loc.T("Drop unused resources"),
        OptimizeStepKind.DownsampleImages => Loc.T("Shrink pictures"),
        OptimizeStepKind.BilevelImages => Loc.T("Make black and white pictures 1-bit"),
        OptimizeStepKind.SubsetFonts => Loc.T("Trim fonts"),
        OptimizeStepKind.Grayscale => Loc.T("Convert to grayscale"),
        _ => kind.ToString(),
    };

    public static string KindName(SpaceKind kind) => kind switch
    {
        SpaceKind.Images => Loc.T("Pictures"),
        SpaceKind.Fonts => Loc.T("Fonts"),
        SpaceKind.Content => Loc.T("Page content"),
        SpaceKind.Forms => Loc.T("Forms"),
        SpaceKind.Annotations => Loc.T("Annotations"),
        SpaceKind.Metadata => Loc.T("Metadata"),
        SpaceKind.Structure => Loc.T("Structure"),
        SpaceKind.Attachments => Loc.T("Attachments"),
        SpaceKind.Overhead => Loc.T("File overhead"),
        SpaceKind.Unreferenced => Loc.T("Unused data"),
        _ => kind.ToString(),
    };

    public static string ItemName(SanitizeItem item) => item switch
    {
        SanitizeItem.JavaScript => Loc.T("JavaScript"),
        SanitizeItem.LaunchActions => Loc.T("Actions that launch or open other files"),
        SanitizeItem.EmbeddedFiles => Loc.T("Attached files"),
        SanitizeItem.HiddenLayers => Loc.T("Hidden layers"),
        SanitizeItem.HiddenText => Loc.T("Hidden text"),
        SanitizeItem.InvisibleText => Loc.T("Invisible text"),
        SanitizeItem.Comments => Loc.T("Comments and markup"),
        SanitizeItem.FormData => Loc.T("Form data"),
        SanitizeItem.Metadata => Loc.T("Document information and metadata"),
        SanitizeItem.PieceInfo => Loc.T("Application data"),
        SanitizeItem.Thumbnails => Loc.T("Page thumbnails"),
        SanitizeItem.PreviousVersions => Loc.T("Earlier versions"),
        SanitizeItem.SearchIndexes => Loc.T("Search and web capture data"),
        SanitizeItem.ExternalLinks => Loc.T("Links to the outside"),
        SanitizeItem.FilePaths => Loc.T("File names and paths"),
        SanitizeItem.Signatures => Loc.T("Digital signatures"),
        _ => item.ToString(),
    };

    public static string NeedsCodec => Loc.T("Pictures in JPEG and JPEG 2000 need the system codec and were left.");
    public static string LeftColor => Loc.T("Shadings, spot colors and patterns were left in color.");
    public static string LeftPartialFonts => Loc.T("Fonts with uses that could not be traced were left whole.");
    public static string LeftPartialImages => Loc.T("Pictures with uses that could not be traced were left at their size.");
    public static string LeftMixedText => Loc.T("Invisible text in a text object that also shows visible text was left.");
}
