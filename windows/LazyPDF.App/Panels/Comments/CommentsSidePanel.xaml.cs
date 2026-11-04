using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Comments;

/// <summary>One comment in the list.</summary>
public sealed class CommentRow(PdfComment comment, string where)
{
    public PdfComment Comment { get; } = comment;

    public string Title => string.IsNullOrEmpty(Comment.Author) ? AnnotationText.KindName(Comment.Type) : AnnotationText.KindName(Comment.Type) + " · " + Comment.Author;

    public string Text => Comment.Text ?? "";

    public Visibility TextVisibility => Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

    public string Where { get; } = comment.Replies.Count > 0 ? where + " · " + Loc.Plural(comment.Replies.Count, "{0} reply", "{0} replies", comment.Replies.Count) : where;

    public string Summary => Title + ", " + Where + (Text.Length > 0 ? ", " + Text : "");
}

/// <summary>Every comment and mark of the file in page order; a click shows it on its page.</summary>
public partial class CommentsSidePanel : ToolPanel
{
    public CommentsSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Build();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Comments.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Build()
    {
        var comments = PdfComments.List(Tab!.Document);
        Comments.ItemsSource = comments.Select(c => new CommentRow(c, Loc.T("Page {0}", Viewer!.PageLabel(c.PageIndex)))).ToList();
        Empty.Visibility = comments.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Go(CommentRow row)
    {
        if (Viewer is not { } viewer || row.Comment.PageIndex < 0) return;
        int page = row.Comment.PageIndex;
        var box = viewer.Geometry(page).ToDisplay(row.Comment.Annotation.Rect);
        viewer.GoToPage(page);
        viewer.Reveal(page, new Rect(box.X, box.Y, box.Width, box.Height));
    }

    private void Comments_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is CommentRow row) Go(row);
    }

    private void Comments_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Comments.SelectedItem is CommentRow row)
        {
            Go(row);
            e.Handled = true;
        }
    }
}
