using System.Windows;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Comments;

/// <summary>One comment in the list. <paramref name="group"/> is the heading it sits under.</summary>
public sealed class CommentRow(PdfComment comment, string where, string group)
{
    public PdfComment Comment { get; } = comment;

    public string Group { get; } = group;

    public string Title => string.IsNullOrEmpty(Comment.Author) ? AnnotationText.KindName(Comment.Type) : AnnotationText.KindName(Comment.Type) + " · " + Comment.Author;

    public string Text => Comment.Text ?? "";

    public Visibility TextVisibility => Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

    public string Where { get; } = Details(comment, where);

    public string Summary => Title + ", " + Where + (Text.Length > 0 ? ", " + Text : "");

    private static string Details(PdfComment comment, string where)
    {
        if (comment.Status != ReviewStatus.None) where += " · " + AnnotationText.StatusName(comment.Status);
        int answers = comment.Replies.Count(r => r.State is null);
        if (answers > 0) where += " · " + Loc.Plural(answers, "{0} reply", "{0} replies");
        return where;
    }
}
