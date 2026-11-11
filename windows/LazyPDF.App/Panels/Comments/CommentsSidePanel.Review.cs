// Answering, editing and deleting the comment that is picked, and the summary file.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Comment;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Comments;

public partial class CommentsSidePanel
{
    private readonly SystemFontSource _fonts = new();
    private int? _detailNumber;

    private void Comments_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading) ShowDetail();
    }

    private void ShowDetail()
    {
        EndEdit();
        if (Comments.SelectedItem is not CommentRow row)
        {
            Detail.Visibility = Visibility.Collapsed;
            _detailNumber = null;
            return;
        }
        Detail.Visibility = Visibility.Visible;
        // An annotation written straight into the page's list has no object number to answer.
        Answering.IsEnabled = _allowed && row.Comment.Annotation.Reference is not null;
        EditButton.IsEnabled = DeleteButton.IsEnabled = _allowed;
        int? number = row.Comment.Annotation.Reference?.Number;
        if (number is null || number != _detailNumber) TextScroll.ScrollToTop();
        _detailNumber = number;
        FullText.Text = row.Text;
        FullText.Visibility = row.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Replies.ItemsSource = row.Comment.Replies.Where(r => r.State is null && !string.IsNullOrWhiteSpace(r.Contents))
            .Select(r => string.IsNullOrEmpty(r.Title) ? r.Contents : r.Title + ": " + r.Contents).ToList();
        _loading = true;
        StatusBox.SelectedItem = StatusBox.Items.Cast<StatusChoice>().FirstOrDefault(s => s.Status == row.Comment.Status);
        _loading = false;
    }

    // The text box's own scroller would swallow the wheel without moving anything.
    private void FullText_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        TextScroll.ScrollToVerticalOffset(TextScroll.VerticalOffset - e.Delta);
        e.Handled = true;
    }

    private void EndEdit()
    {
        FullText.IsReadOnly = true;
        FullText.AcceptsReturn = false;
        Editing.Visibility = Visibility.Collapsed;
        Answering.Visibility = Visibility.Visible;
    }

    private void Edit_Click(object sender, RoutedEventArgs e)
    {
        if (!_allowed || Comments.SelectedItem is null) return;
        FullText.IsReadOnly = false;
        FullText.AcceptsReturn = true;
        FullText.Visibility = Visibility.Visible;
        Answering.Visibility = Visibility.Collapsed;
        Editing.Visibility = Visibility.Visible;
        FullText.Focus();
        FullText.CaretIndex = FullText.Text.Length;
    }

    private void CancelEdit_Click(object sender, RoutedEventArgs e) => ShowDetail();

    private void FullText_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (FullText.IsReadOnly) return;
        if (e.Key == Key.Escape) ShowDetail();
        else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control) SaveEdit_Click(sender, e);
        else return;
        e.Handled = true;
    }

    private void SaveEdit_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running || Comments.SelectedItem is not CommentRow row) return;
        string text = FullText.Text;
        if (text == row.Text)
        {
            ShowDetail();
            return;
        }
        if (MarkWork.Cautioned(tab, host, () => SaveText(tab, host, row, text))) return;
        SaveText(tab, host, row, text);
    }

    private void SaveText(DocumentTab tab, IToolHost host, CommentRow row, string text)
    {
        if (!ReferenceEquals(Tab, tab) || MarkWork.Running) return;
        try
        {
            new PdfAnnotationWriter(tab.Document, _fonts).SetContents(row.Comment.Annotation, text, DateTimeOffset.Now);
        }
        catch (Exception error) when (error is ArgumentException or PdfReadException)
        {
            tab.Session.Discard();
            host.ShowProblem(new Problem(Loc.T("Comment not changed"), Loc.T("The file would not take that text. Try other words.")));
            return;
        }
        if (MarkWork.Commit(tab, host, Loc.T("Edit comment"))) host.SetStatus(Loc.T("Comment changed."));
    }

    private void Delete_Click(object sender, RoutedEventArgs e) => DeleteSelected();

    private void DeleteSelected()
    {
        if (!_allowed || Tab is not { } tab || Host is not { } host || MarkWork.Running || Comments.SelectedItem is not CommentRow row) return;
        if (MarkWork.Cautioned(tab, host, () => Delete(tab, host, row))) return;
        Delete(tab, host, row);
    }

    private void Delete(DocumentTab tab, IToolHost host, CommentRow row)
    {
        if (!ReferenceEquals(Tab, tab) || MarkWork.Running) return;
        int index = Comments.SelectedIndex;
        if (!new PdfAnnotationWriter(tab.Document, _fonts).Delete(row.Comment.Annotation))
        {
            host.SetStatus(Loc.T("That comment is no longer in the file."));
            return;
        }
        if (!MarkWork.Commit(tab, host, Loc.T("Delete comment"))) return;
        if (Comments.Items.Count > 0) Comments.SelectedIndex = Math.Min(index, Comments.Items.Count - 1);
        host.SetStatus(Loc.T("Comment deleted."));
    }

    private void ReplyBox_TextChanged(object sender, TextChangedEventArgs e) => ReplyButton.IsEnabled = ReplyBox.Text.Trim().Length > 0;

    private void Reply_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running || Comments.SelectedItem is not CommentRow row || ReplyBox.Text.Trim() is not { Length: > 0 } text) return;
        if (MarkWork.Cautioned(tab, host, () => Reply(tab, host, row, text))) return;
        Reply(tab, host, row, text);
    }

    private void Reply(DocumentTab tab, IToolHost host, CommentRow row, string text)
    {
        if (!ReferenceEquals(Tab, tab) || MarkWork.Running) return;
        if (!Answer(tab, host, Loc.T("Reply"), () => PdfComments.Reply(tab.Document, row.Comment.Annotation, text, Environment.UserName, DateTimeOffset.Now))) return;
        ReplyBox.Clear();
        // The card was rebuilt; the new reply sits at the end and only has a place once laid out.
        Dispatcher.BeginInvoke(TextScroll.ScrollToEnd, DispatcherPriority.Loaded);
    }

    private void Status_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || Tab is not { } tab || Host is not { } host || MarkWork.Running || Comments.SelectedItem is not CommentRow row || StatusBox.SelectedItem is not StatusChoice { Status: { } status }) return;
        if (status == row.Comment.Status) return;
        if (MarkWork.Cautioned(tab, host, () => SetStatus(tab, host, row, status)))
        {
            ShowDetail();
            return;
        }
        SetStatus(tab, host, row, status);
    }

    private void SetStatus(DocumentTab tab, IToolHost host, CommentRow row, ReviewStatus status)
    {
        if (!ReferenceEquals(Tab, tab) || MarkWork.Running) return;
        if (!Answer(tab, host, Loc.T("Set status"), () => PdfComments.SetStatus(tab.Document, row.Comment.Annotation, status, Environment.UserName, DateTimeOffset.Now))) ShowDetail();
    }

    private static bool Answer(DocumentTab tab, IToolHost host, string label, Action write)
    {
        try
        {
            write();
        }
        catch (ArgumentException)
        {
            tab.Session.Discard();
            host.ShowProblem(new Problem(Loc.T("This comment cannot be answered"), Loc.T("Its file stores it in a way that has no room for replies. Add a note next to it.")));
            return false;
        }
        return MarkWork.Commit(tab, host, label);
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Viewer is not { } viewer || Host is not { } host) return;
        var comments = Visible();
        if (comments.Count == 0)
        {
            host.SetStatus(Loc.T("No comments to export."));
            return;
        }
        var dialog = new SaveFileDialog
        {
            Title = Loc.T("Save summary of the comments"),
            Filter = Loc.T("Text files") + "|*.txt",
            DefaultExt = ".txt",
            AddExtension = true,
            OverwritePrompt = true,
            FileName = Path.GetFileNameWithoutExtension(tab.Title) + " " + Loc.T("Comments"),
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            File.WriteAllText(dialog.FileName, CommentSummary.Text(tab.Title, comments, viewer.PageLabel));
            host.SetStatus(comments.Count < _all.Count
                ? Loc.T("Summary of {0} of {1} comments saved.", comments.Count, _all.Count)
                : Loc.T("Summary saved."));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(new Problem(Loc.T("Not saved"), Loc.T("{0} could not be written. Check that the disk has room and try again.", Path.GetFileName(dialog.FileName))));
        }
    }
}
