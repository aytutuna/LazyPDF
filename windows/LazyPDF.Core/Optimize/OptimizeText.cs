namespace LazyPDF.Core;

/// <summary>User-visible words of the optimizer and the sanitizer.</summary>
public static class OptimizeText
{
    public static string StepName(OptimizeStepKind kind) => kind switch
    {
        OptimizeStepKind.RemoveUnreferenced => "Remove unused objects",
        OptimizeStepKind.ObjectStreams => "Pack objects",
        OptimizeStepKind.RecompressStreams => "Recompress streams",
        OptimizeStepKind.ConvertOldFilters => "Replace old filters",
        OptimizeStepKind.RemoveDuplicates => "Merge duplicates",
        OptimizeStepKind.StripThumbnails => "Remove thumbnails",
        OptimizeStepKind.StripPieceInfo => "Remove application data",
        OptimizeStepKind.StripPrivateData => "Remove private keys",
        OptimizeStepKind.PruneResources => "Drop unused resources",
        OptimizeStepKind.DownsampleImages => "Shrink images",
        OptimizeStepKind.BilevelImages => "Make black and white images 1-bit",
        OptimizeStepKind.SubsetFonts => "Trim fonts",
        OptimizeStepKind.Grayscale => "Convert to grayscale",
        _ => kind.ToString(),
    };

    public static string KindName(SpaceKind kind) => kind switch
    {
        SpaceKind.Images => "Images",
        SpaceKind.Fonts => "Fonts",
        SpaceKind.Content => "Page content",
        SpaceKind.Forms => "Forms",
        SpaceKind.Annotations => "Annotations",
        SpaceKind.Metadata => "Metadata",
        SpaceKind.Structure => "Structure",
        SpaceKind.Attachments => "Attachments",
        SpaceKind.Overhead => "File overhead",
        SpaceKind.Unreferenced => "Unused data",
        _ => kind.ToString(),
    };

    public static string ItemName(SanitizeItem item) => item switch
    {
        SanitizeItem.JavaScript => "JavaScript",
        SanitizeItem.LaunchActions => "Actions that launch or open other files",
        SanitizeItem.EmbeddedFiles => "Attached files",
        SanitizeItem.HiddenLayers => "Hidden layers",
        SanitizeItem.HiddenText => "Hidden text",
        SanitizeItem.InvisibleText => "Invisible text",
        SanitizeItem.Comments => "Comments and markup",
        SanitizeItem.FormData => "Form data",
        SanitizeItem.Metadata => "Document information and metadata",
        SanitizeItem.PieceInfo => "Application data",
        SanitizeItem.Thumbnails => "Page thumbnails",
        SanitizeItem.PreviousVersions => "Earlier versions",
        SanitizeItem.SearchIndexes => "Search and web capture data",
        SanitizeItem.ExternalLinks => "Links to the outside",
        SanitizeItem.FilePaths => "File names and paths",
        _ => item.ToString(),
    };

    public const string NeedsCodec = "Images in JPEG and JPEG 2000 need the system codec and were left.";
    public const string LeftColor = "Shadings, spot colours and patterns were left in colour.";
    public const string LeftPartialFonts = "Fonts with uses that could not be traced were left whole.";
    public const string LeftMixedText = "Invisible text in a text object that also shows visible text was left.";
}
