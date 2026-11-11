using System.Collections.ObjectModel;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>A match and the words around it, for the list in the Search panel.</summary>
public sealed record SearchHit(SearchMatch Match, string Before, string After)
{
    public int Page => Match.Page;

    public string Text => Match.Text;

    /// <summary>The page's own label, when the file has one.</summary>
    public string? Label { get; init; }

    public string PageText => Loc.T("Page {0}", Label ?? (Page + 1).ToString());

    /// <summary>What a screen reader says for the row: the page, then the words around the match.</summary>
    public string Spoken => $"{PageText}. {Before}{Text}{After}";
}

public enum SearchWrap { None, Start, End }

/// <summary>
/// One search of the open file, shared by the find bar, the highlights on the pages and the Search panel.
/// It runs off the UI thread and delivers hits in batches through <c>post</c>; starting another search
/// cancels the one running.
/// </summary>
public sealed class ViewerSearch
{
    private const int Context = 32;
    private const int Batch = 25;

    private readonly Func<Task<TextSource?>> _source;
    private readonly Func<int> _startPage;
    private readonly Action<Action> _post;
    private readonly Func<int, string>? _pageLabel;
    private CancellationTokenSource? _cancel;
    private bool _quiet;
    private int _landed = -1;

    /// <param name="source">The text of the file; null when it cannot be read.</param>
    /// <param name="startPage">The page the first current hit is taken from.</param>
    /// <param name="post">Runs an action on the thread the hits and events belong to.</param>
    /// <param name="pageLabel">The label of a page, read on the post thread; null numbers hits by page.</param>
    public ViewerSearch(Func<Task<TextSource?>> source, Func<int> startPage, Action<Action> post, Func<int, string>? pageLabel = null)
    {
        _source = source;
        _startPage = startPage;
        _post = post;
        _pageLabel = pageLabel;
    }

    public ObservableCollection<SearchHit> Hits { get; } = [];

    public string Query { get; private set; } = "";

    public TextSearchOptions Options { get; private set; } = new();

    /// <summary>The hit the viewer is at, or -1.</summary>
    public int Current { get; private set; } = -1;

    public bool Running { get; private set; }

    /// <summary>Whether the last step went round the end of the hits, and which way.</summary>
    public SearchWrap Wrapped { get; private set; }

    /// <summary>The query is a regular expression that does not parse.</summary>
    public bool BadPattern { get; private set; }

    /// <summary>The search found nothing and no page of the file has text, as in a scan.</summary>
    public bool NoText { get; private set; }

    /// <summary>Raised when the query, the hits or whether it is still running changed.</summary>
    public event EventHandler? Changed;

    /// <summary>Raised when <see cref="Current"/> moved, so the view goes to it.</summary>
    public event EventHandler? CurrentChanged;

    /// <summary>Searches for <paramref name="query"/>; an empty one clears. The task ends when the search has.</summary>
    public Task Start(string query, TextSearchOptions options)
    {
        _quiet = false;
        _cancel?.Cancel();
        Hits.Clear();
        Current = -1;
        _landed = -1;
        Wrapped = SearchWrap.None;
        Query = query;
        Options = options;
        BadPattern = false;
        NoText = false;
        if (query.Length == 0)
        {
            Running = false;
            Changed?.Invoke(this, EventArgs.Empty);
            return Task.CompletedTask;
        }
        var cancel = _cancel = new CancellationTokenSource();
        Running = true;
        Changed?.Invoke(this, EventArgs.Empty);
        int start = _startPage();
        var source = _source();
        return Task.Run(() => RunAsync(source, query, options, start, cancel.Token));
    }

    public void Clear() => Start("", Options);

    /// <summary>Searches again for the same query after the file changed. The view stays where it is: only the user's own moves go to a hit.</summary>
    public Task Restart()
    {
        var task = Start(Query, Options);
        _quiet = true;
        return task;
    }

    public void Next() => Move(1);

    public void Previous() => Move(-1);

    private void Move(int step)
    {
        int count = Hits.Count;
        if (count == 0) return;
        _quiet = false;
        int start = _startPage();
        int index;
        if (Current >= 0 && start != _landed && Math.Abs(Hits[Current].Page - start) > 1)
        {
            // The reader scrolled away after finding, so step from the page in view.
            index = step > 0 ? count : -1;
            if (step > 0)
            {
                for (int i = 0; i < count; i++)
                    if (Hits[i].Page >= start) { index = i; break; }
            }
            else
            {
                for (int i = count - 1; i >= 0; i--)
                    if (Hits[i].Page <= start) { index = i; break; }
            }
            // The hit in view is already shown, so go one further.
            if (index == Current) index += step;
        }
        else index = (Current < 0 ? (step > 0 ? -1 : 0) : Current) + step;
        var wrap = SearchWrap.None;
        if (index < 0 || index >= count)
        {
            // More hits may still arrive, so only a finished search wraps.
            if (Running && Current >= 0) return;
            if (Current >= 0) wrap = step > 0 ? SearchWrap.Start : SearchWrap.End;
            index = (index + count) % count;
        }
        Wrapped = wrap;
        SelectAt(index);
    }

    public void Select(int index)
    {
        if ((uint)index >= (uint)Hits.Count) return;
        Wrapped = SearchWrap.None;
        SelectAt(index);
    }

    private void SelectAt(int index)
    {
        _quiet = false;
        Current = index;
        Changed?.Invoke(this, EventArgs.Empty);
        MoveView();
    }

    // The page in view once the view has gone to the hit: Next steps on from the hit while it is still there, even when the hit was already on screen.
    private void MoveView()
    {
        CurrentChanged?.Invoke(this, EventArgs.Empty);
        _landed = _startPage();
    }

    private async Task RunAsync(Task<TextSource?> sourceTask, string query, TextSearchOptions options, int start, CancellationToken cancel)
    {
        bool bad = false;
        bool noText = false;
        try
        {
            if (await sourceTask is { } source)
            {
                var batch = new List<SearchHit>();
                bool found = false;
                foreach (var match in source.Find(query, options, cancel))
                {
                    found = true;
                    batch.Add(new SearchHit(match, Around(source, match, -1), Around(source, match, 1)));
                    if (batch.Count >= Batch) Flush(batch, start, cancel);
                }
                Flush(batch, start, cancel);
                if (!found && !cancel.IsCancellationRequested)
                {
                    noText = true;
                    for (int i = 0; i < source.PageCount && noText; i++) noText = source.Page(i).Chars.Count == 0;
                }
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (ArgumentException)
        {
            bad = true;
        }
        _post(() =>
        {
            if (cancel.IsCancellationRequested) return;
            Running = false;
            BadPattern = bad;
            NoText = noText;
            if (Current < 0 && Hits.Count > 0)
            {
                Current = 0;
                if (!_quiet) MoveView();
            }
            Changed?.Invoke(this, EventArgs.Empty);
        });
    }

    private void Flush(List<SearchHit> batch, int start, CancellationToken cancel)
    {
        if (batch.Count == 0) return;
        var hits = batch.ToArray();
        batch.Clear();
        _post(() =>
        {
            if (cancel.IsCancellationRequested) return;
            bool first = Current < 0;
            foreach (var hit in hits)
            {
                Hits.Add(hit with { Label = _pageLabel?.Invoke(hit.Page) });
                if (Current < 0 && hit.Page >= start) Current = Hits.Count - 1;
            }
            Changed?.Invoke(this, EventArgs.Empty);
            if (first && Current >= 0 && !_quiet) MoveView();
        });
    }

    private static string Around(TextSource source, SearchMatch match, int side)
    {
        var page = source.Page(match.Page);
        int length = page.Chars.Count;
        var range = side < 0
            ? new TextRange(Math.Max(0, match.Range.Start - Context), match.Range.Start)
            : new TextRange(match.Range.End, Math.Min(length, match.Range.End + Context));
        return range.IsEmpty ? "" : page.GetText(range).Replace('\n', ' ').Replace('\t', ' ');
    }
}
