using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Comment;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Comments;

/// <summary>Every comment and mark of the file, grouped and filtered; a click shows it on its page, and the one picked can be answered.</summary>
public partial class CommentsSidePanel : ToolPanel
{
    private sealed record Grouping(CommentOrder Order, string Name);

    private sealed record StatusChoice(ReviewStatus? Status, string Name);

    private readonly DispatcherTimer _typing = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private IReadOnlyList<PdfComment> _all = [];
    private bool _loading = true;
    private bool _allowed = true;

    public CommentsSidePanel()
    {
        InitializeComponent();
        GroupBy.ItemsSource = new Grouping[] { new(CommentOrder.Page, Loc.T("By page")), new(CommentOrder.Date, Loc.T("By date")), new(CommentOrder.Author, Loc.T("By author")), new(CommentOrder.Type, Loc.T("By type")) };
        GroupBy.DisplayMemberPath = nameof(Grouping.Name);
        GroupBy.SelectedIndex = 0;
        var statuses = new[] { ReviewStatus.None, ReviewStatus.Accepted, ReviewStatus.Rejected, ReviewStatus.Cancelled, ReviewStatus.Completed };
        // Marked is a separate model, but the list shows only the newest state, so it can be filtered on and not set.
        StatusFilter.ItemsSource = new[] { new StatusChoice(null, Loc.T("Any status")) }.Concat(statuses.Concat([ReviewStatus.Marked, ReviewStatus.Unmarked]).Select(s => new StatusChoice(s, AnnotationText.StatusName(s)))).ToList();
        StatusFilter.DisplayMemberPath = nameof(StatusChoice.Name);
        StatusFilter.SelectedIndex = 0;
        StatusBox.ItemsSource = statuses.Select(s => new StatusChoice(s, AnnotationText.StatusName(s))).ToList();
        LazyPDF.App.Icon.SetGlyph(ReplyButton, "");
        _typing.Tick += Typing_Tick;
        _loading = false;
    }

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        _allowed = Exchange.CanComment(Tab.Document);
        MoreButton.IsEnabled = true;
        ImportItem.IsEnabled = _allowed;
        Load();
    }

    protected override void OnDetach()
    {
        _typing.Stop();
        MoreButton.IsEnabled = false;
        Tab!.Changed -= Tab_Changed;
        Comments.ItemsSource = null;
        _all = [];
    }

    private void Tab_Changed(object? sender, EventArgs e) => Load();

    private void Filter_Changed(object sender, RoutedEventArgs e)
    {
        SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_loading || Tab is null) return;
        if (sender == Search)
        {
            _typing.Stop();
            _typing.Start();
        }
        else if (sender == GroupBy) Load();
        else Build();
    }

    private void Typing_Tick(object? sender, EventArgs e)
    {
        _typing.Stop();
        if (Tab is not null) Build();
    }

    // The file is read once per change; filtering and typing in the filter work on what was read.
    private void Load()
    {
        var order = (GroupBy.SelectedItem as Grouping)?.Order ?? CommentOrder.Page;
        _all = PdfComments.List(Tab!.Document, null, order, descending: order == CommentOrder.Date);
        Build();
    }

    private IReadOnlyList<PdfComment> Visible()
    {
        var status = (StatusFilter.SelectedItem as StatusChoice)?.Status;
        string query = Search.Text.Trim();
        return [.. _all.Where(c => (status is null || c.Status == status) && (query.Length == 0 || Mentions(c, query)))];
    }

    private static bool Mentions(PdfComment c, string query) =>
        Has(c.Text, query) || Has(c.Author, query) || c.Replies.Any(r => Has(r.Contents, query) || Has(r.Title, query));

    private static bool Has(string? text, string query) => text?.Contains(query, StringComparison.CurrentCultureIgnoreCase) == true;

    private void Build()
    {
        var viewer = Viewer!;
        var order = (GroupBy.SelectedItem as Grouping)?.Order ?? CommentOrder.Page;
        int? picked = (Comments.SelectedItem as CommentRow)?.Comment.Annotation.Reference?.Number;
        var comments = Visible();
        var rows = comments.Select(c => new CommentRow(c, Loc.T("Page {0}", viewer.PageLabel(c.PageIndex)), GroupOf(c, order, viewer))).ToList();
        var view = new ListCollectionView(rows);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(CommentRow.Group)));
        _loading = true;
        Comments.ItemsSource = view;
        Comments.SelectedItem = rows.FirstOrDefault(r => r.Comment.Annotation.Reference?.Number == picked && picked is not null);
        _loading = false;
        ShowDetail();
        bool any = _all.Count > 0;
        Empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Empty.Text = any ? Loc.T("No comment matches.") : Loc.T("This file has no comments.");
    }

    private static string GroupOf(PdfComment comment, CommentOrder order, Viewer.IDocumentViewer viewer) => order switch
    {
        CommentOrder.Date => comment.Date is { } d ? d.ToLocalTime().Date.ToString("d", CultureInfo.CurrentCulture) : Loc.T("No date"),
        CommentOrder.Author => string.IsNullOrEmpty(comment.Author) ? Loc.T("No author") : comment.Author,
        CommentOrder.Type => AnnotationText.KindName(comment.Type),
        _ => Loc.T("Page {0}", viewer.PageLabel(comment.PageIndex)),
    };

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
        else if (e.Key == Key.Delete)
        {
            DeleteSelected();
            e.Handled = true;
        }
    }
}
