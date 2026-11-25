namespace LazyPDF.Core;

public static class AnnotationText
{
    public static string Undrawn(string characters) => Loc.T("No installed font has these characters, so they are left blank: {0}", characters);

    public static string NoFont => Loc.T("No font can draw this text. Choose another font.");

    public static string KindName(AnnotationType type) => type switch
    {
        AnnotationType.Text => Loc.T("Note"),
        AnnotationType.FreeText => Loc.T("Text box"),
        AnnotationType.Line => Loc.T("Line"),
        AnnotationType.Square => Loc.T("Rectangle"),
        AnnotationType.Circle => Loc.T("Oval"),
        AnnotationType.Polygon => Loc.T("Polygon"),
        AnnotationType.PolyLine => Loc.T("Polyline"),
        AnnotationType.Highlight => Loc.T("Highlight"),
        AnnotationType.Underline => Loc.T("Underline"),
        AnnotationType.Squiggly => Loc.T("Squiggly underline"),
        AnnotationType.StrikeOut => Loc.T("Strikethrough"),
        AnnotationType.Stamp => Loc.T("Stamp"),
        AnnotationType.Caret => Loc.T("Insert text"),
        AnnotationType.Ink => Loc.T("Drawing"),
        AnnotationType.FileAttachment => Loc.T("Attachment"),
        AnnotationType.Redact => Loc.T("Redaction"),
        AnnotationType.Link => Loc.T("Link"),
        _ => Loc.T("Annotation"),
    };

    public static string StatusName(ReviewStatus status) => status switch
    {
        ReviewStatus.Accepted => Loc.T("Accepted"),
        ReviewStatus.Rejected => Loc.T("Rejected"),
        ReviewStatus.Cancelled => Loc.T("Canceled"),
        ReviewStatus.Completed => Loc.T("Completed"),
        ReviewStatus.Marked => Loc.T("Marked"),
        ReviewStatus.Unmarked => Loc.T("Unmarked"),
        _ => Loc.T("None"),
    };

    public static string StatusSetBy(ReviewStatus status, string author) => Loc.T("{0} set by {1}", StatusName(status), author);

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
