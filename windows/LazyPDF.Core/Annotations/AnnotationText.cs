namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class AnnotationText
{
    public static string NoFont => "No font can draw this text. Choose another font.";

    public static string KindName(AnnotationType type) => type switch
    {
        AnnotationType.Text => "Note",
        AnnotationType.FreeText => "Text box",
        AnnotationType.Line => "Line",
        AnnotationType.Square => "Rectangle",
        AnnotationType.Circle => "Oval",
        AnnotationType.Polygon => "Polygon",
        AnnotationType.PolyLine => "Polyline",
        AnnotationType.Highlight => "Highlight",
        AnnotationType.Underline => "Underline",
        AnnotationType.Squiggly => "Squiggly underline",
        AnnotationType.StrikeOut => "Strikethrough",
        AnnotationType.Stamp => "Stamp",
        AnnotationType.Caret => "Insert text",
        AnnotationType.Ink => "Drawing",
        AnnotationType.FileAttachment => "Attachment",
        AnnotationType.Redact => "Redaction",
        AnnotationType.Link => "Link",
        _ => "Annotation",
    };

    public static string StatusName(ReviewStatus status) => status switch
    {
        ReviewStatus.Accepted => "Accepted",
        ReviewStatus.Rejected => "Rejected",
        ReviewStatus.Cancelled => "Cancelled",
        ReviewStatus.Completed => "Completed",
        ReviewStatus.Marked => "Marked",
        ReviewStatus.Unmarked => "Unmarked",
        _ => "None",
    };

    public static string StatusSetBy(ReviewStatus status, string author) => $"{StatusName(status)} set by {author}";

    /// <summary>The standard stamp names of ISO 32000-1 12.5.6.12, in the order a palette shows them.</summary>
    public static IReadOnlyList<string> StandardStamps { get; } =
    [
        "Approved", "NotApproved", "Draft", "Final", "Confidential", "ForComment", "ForPublicRelease", "NotForPublicRelease",
        "AsIs", "Experimental", "Expired", "Sold", "Departmental", "TopSecret",
    ];

    /// <summary>What a stamp says: the words of a standard name in capitals, a custom name as it is.</summary>
    public static string StampLabel(string name) => name switch
    {
        "Approved" => "APPROVED",
        "NotApproved" => "NOT APPROVED",
        "Draft" => "DRAFT",
        "Final" => "FINAL",
        "Confidential" => "CONFIDENTIAL",
        "ForComment" => "FOR COMMENT",
        "ForPublicRelease" => "FOR PUBLIC RELEASE",
        "NotForPublicRelease" => "NOT FOR PUBLIC RELEASE",
        "AsIs" => "AS IS",
        "Experimental" => "EXPERIMENTAL",
        "Expired" => "EXPIRED",
        "Sold" => "SOLD",
        "Departmental" => "DEPARTMENTAL",
        "TopSecret" => "TOP SECRET",
        _ => name,
    };
}
