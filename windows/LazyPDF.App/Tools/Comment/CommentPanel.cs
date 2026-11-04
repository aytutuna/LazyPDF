namespace LazyPDF.App.Tools.Comment;

public sealed class CommentPanel : ToolPanel
{
    public CommentPanel() => Content = new StubNote("comment");
}
