using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Comments;

/// <summary>The comments of a file as plain text, to hand to someone who has no PDF reader open.</summary>
public static class CommentSummary
{
    public static string Text(string title, IReadOnlyList<PdfComment> comments, Func<int, string> pageLabel)
    {
        var text = new StringBuilder();
        text.AppendLine(title);
        text.AppendLine(Loc.Plural(comments.Count, "{0} comment", "{0} comments"));
        foreach (var comment in comments)
        {
            text.AppendLine();
            var head = new List<string> { Loc.T("Page {0}", pageLabel(comment.PageIndex)), AnnotationText.KindName(comment.Type) };
            if (!string.IsNullOrEmpty(comment.Author)) head.Add(comment.Author);
            if (comment.Date is { } date) head.Add(date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            text.AppendLine(string.Join(", ", head));
            if (!string.IsNullOrWhiteSpace(comment.Text)) text.AppendLine("  " + comment.Text.ReplaceLineEndings(" "));
            if (comment.Status != ReviewStatus.None) text.AppendLine("  " + Loc.T("Status: {0}", AnnotationText.StatusName(comment.Status)));
            foreach (var reply in comment.Replies.Where(r => !string.IsNullOrWhiteSpace(r.Contents) && r.State is null))
            {
                text.AppendLine("  " + Loc.T("Reply from {0}: {1}", reply.Title ?? "", reply.Contents!.ReplaceLineEndings(" ")));
            }
        }
        return text.ToString();
    }
}
