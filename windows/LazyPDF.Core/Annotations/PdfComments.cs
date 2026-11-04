namespace LazyPDF.Core;

/// <summary>A comment: a markup annotation that is not a reply, with the replies and review status that hang on it.</summary>
public sealed record PdfComment(PdfAnnotation Annotation, IReadOnlyList<PdfAnnotation> Replies, ReviewStatus Status)
{
    public int PageIndex => Annotation.PageIndex;
    public AnnotationType Type => Annotation.Type;
    public string? Author => Annotation.Title;
    public DateTimeOffset? Date => Annotation.Modified ?? Annotation.Created;

    /// <summary>/Contents, or the plain text of the rich text when that is all the annotation has.</summary>
    public string? Text => Annotation.Contents is { Length: > 0 } text ? text : Annotation.RichText is { Length: > 0 } rich ? PdfRichText.ToPlain(rich) : null;
}

public enum CommentOrder
{
    /// <summary>Page by page, top to bottom, left to right.</summary>
    Page,
    Date,
    Author,
    Type,
}

/// <summary>
/// What to keep in a comment list; a null member keeps everything. <see cref="Author"/> and
/// <see cref="Text"/> match ignoring case and also look at the replies.
/// </summary>
public sealed record CommentFilter(string? Author = null, string? Text = null, ReviewStatus? Status = null,
    IReadOnlyCollection<AnnotationType>? Types = null, int? PageIndex = null, bool? HasReplies = null);

/// <summary>The comments of a document as one ordered list, and the two ways to answer one (ISO 32000-1 12.5.6.3).</summary>
public static class PdfComments
{
    private const int MaxChain = 64;

    public static IReadOnlyList<PdfComment> List(PdfDocument document, CommentFilter? filter = null, CommentOrder order = CommentOrder.Page, bool descending = false)
    {
        var all = PdfAnnotations.ReadAll(document);
        var byNumber = new Dictionary<int, PdfAnnotation>();
        foreach (var a in all)
        {
            if (a.Reference is { } r) byNumber.TryAdd(r.Number, a);
        }

        var roots = new List<PdfAnnotation>();
        var replies = new Dictionary<PdfAnnotation, List<PdfAnnotation>>();
        foreach (var a in all)
        {
            if (!a.IsMarkup) continue;
            var root = RootOf(a, byNumber);
            if (root is null || ReferenceEquals(root, a)) roots.Add(a);
            else
            {
                if (!replies.TryGetValue(root, out var list)) replies[root] = list = [];
                list.Add(a);
            }
        }

        var comments = roots.Select(r =>
        {
            var thread = replies.GetValueOrDefault(r) ?? [];
            return new PdfComment(r, thread, StatusOf(thread));
        });
        if (filter is not null) comments = comments.Where(c => Matches(c, filter));
        IOrderedEnumerable<PdfComment> first = order switch
        {
            CommentOrder.Date => comments.OrderBy(c => c.Date is null).ThenBy(c => c.Date),
            CommentOrder.Author => comments.OrderBy(c => c.Author ?? "", StringComparer.CurrentCultureIgnoreCase),
            CommentOrder.Type => comments.OrderBy(c => AnnotationText.KindName(c.Type), StringComparer.CurrentCultureIgnoreCase),
            _ => comments.OrderBy(c => c.PageIndex),
        };
        var sorted = first.ThenBy(c => c.PageIndex).ThenByDescending(c => c.Annotation.Rect.Top).ThenBy(c => c.Annotation.Rect.Left);
        return [.. descending ? sorted.Reverse() : sorted];
    }

    // Follows /IRT to the annotation that started the thread; null when the chain breaks or loops.
    private static PdfAnnotation? RootOf(PdfAnnotation a, Dictionary<int, PdfAnnotation> byNumber)
    {
        var current = a;
        for (int hops = 0; hops < MaxChain; hops++)
        {
            if (current.InReplyTo is not { } parent || !byNumber.TryGetValue(parent.Number, out var next)) return current;
            current = next;
        }
        return null;
    }

    private static ReviewStatus StatusOf(List<PdfAnnotation> thread) =>
        thread.Where(r => r.State is not null).OrderBy(r => r.Modified ?? r.Created ?? DateTimeOffset.MinValue).LastOrDefault()?.State ?? ReviewStatus.None;

    private static bool Matches(PdfComment c, CommentFilter f)
    {
        if (f.PageIndex is { } page && c.PageIndex != page) return false;
        if (f.Status is { } status && c.Status != status) return false;
        if (f.Types is not null && !f.Types.Contains(c.Type)) return false;
        if (f.HasReplies is { } has && has != (c.Replies.Count > 0)) return false;
        if (f.Author is { Length: > 0 } author && !Mentions(author, c.Author, c.Replies.Select(r => r.Title))) return false;
        if (f.Text is { Length: > 0 } text && !Mentions(text, c.Text, c.Replies.Select(r => r.Contents))) return false;
        return true;
    }

    private static bool Mentions(string needle, string? own, IEnumerable<string?> others) =>
        own?.Contains(needle, StringComparison.CurrentCultureIgnoreCase) == true
        || others.Any(o => o?.Contains(needle, StringComparison.CurrentCultureIgnoreCase) == true);

    /// <summary>Adds a reply (a hidden note pointing back at <paramref name="parent"/>, /RT /R) and returns it.</summary>
    public static PdfAnnotation Reply(PdfDocument document, PdfAnnotation parent, string text, string author, DateTimeOffset date) =>
        new PdfAnnotationWriter(document).AddReply(parent, new AnnotationInfo(author, text, null, date), null);

    /// <summary>
    /// Records a review status on a comment as a reply carrying /State: the Review model for
    /// None, Accepted, Rejected, Cancelled and Completed, the Marked model for Marked and Unmarked.
    /// </summary>
    public static PdfAnnotation SetStatus(PdfDocument document, PdfAnnotation parent, ReviewStatus status, string author, DateTimeOffset date) =>
        new PdfAnnotationWriter(document).AddReply(parent, new AnnotationInfo(author, AnnotationText.StatusSetBy(status, author), null, date), status);
}
