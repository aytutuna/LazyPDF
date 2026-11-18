using LazyPDF.App.Documents;

namespace LazyPDF.App.Services;

/// <summary>Where a file that is being opened is already held: the view model, and its tab unless the file waits at a password question.</summary>
internal sealed record OpenHit(AppViewModel Owner, DocumentTab? Tab);

/// <summary>
/// The view models of every window in the process, so a file is held by one tab however it is named and a tab can be
/// found by its id. One per process, used on the UI thread only: tabs rely on the dispatcher they were made on, so all
/// windows share one thread.
/// </summary>
public sealed class DocumentRegistry
{
    private readonly List<AppViewModel> _models = [];
    private readonly Dictionary<string, TaskCompletionSource> _paths = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, TaskCompletionSource> _files = [];

    internal IReadOnlyList<AppViewModel> Models => _models;

    internal void Add(AppViewModel model) => _models.Add(model);

    internal void Remove(AppViewModel model) => _models.Remove(model);

    /// <summary>The view model whose strip has the tab with this id; null when none has it.</summary>
    internal AppViewModel? Find(Guid id) => _models.FirstOrDefault(m => m.Documents.Any(d => d.Id == id));

    /// <summary>The tab, or the password question, that holds the file named by <paramref name="path"/> or by <paramref name="fileId"/>, in any window.</summary>
    internal OpenHit? FindOpen(string? path, string? fileId)
    {
        foreach (var model in _models)
            if (model.Holds(path, fileId) is { } hit) return hit;
        return null;
    }

    /// <summary>
    /// Moves the tab itself from one window to another, inserted at <paramref name="index"/>; nothing is copied, so the
    /// edits, undo history, recovery copy and password go with it. Refusals and failures say why in the source window
    /// and leave the tab where it was. <paramref name="targetFree"/> is the target window's own check (see
    /// <see cref="AppViewModel.CanAdopt"/>).
    /// </summary>
    internal bool Transfer(DocumentTab tab, AppViewModel from, AppViewModel to, int index, bool targetFree = true)
    {
        if (ReferenceEquals(from, to) || Find(tab.Id) != from) return false;
        string? reason;
        if (!from.CanRelease(tab, out reason) || !to.CanAdopt(targetFree, out reason))
        {
            from.ShowNotice(Loc.T("Tab not moved"), reason);
            return false;
        }
        var before = from.ActiveTab;
        int at = from.Strip.IndexOf(tab);
        try
        {
            from.Release(tab);
            to.Adopt(tab, index);
            return true;
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceError(e.ToString());
        }
        // The tab goes back the way it came: out of the target first, so it is never in two strips.
        Quietly(() => to.Release(tab), to.Strip.Contains(tab));
        Quietly(() => from.Adopt(tab, at), !from.Strip.Contains(tab));
        Quietly(() => from.ActiveTab = before, from.Strip.Contains(before));
        Quietly(() => from.ShowProblem(new Problem(Loc.T("Tab not moved"), Loc.T("Something went wrong, so {0} stays in this window.", tab.Title))), true);
        return false;
    }

    // A window that fails to draw has already changed its strip by then, so a failure here is only logged.
    private static void Quietly(Action step, bool needed)
    {
        if (!needed) return;
        try
        {
            step();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceError(e.ToString());
        }
    }

    /// <summary>Takes the right to open <paramref name="path"/>; when another open has it, returns the task that ends when that one does.</summary>
    internal Task? ClaimPath(string path, out IDisposable? claim) => Take(_paths, path, out claim);

    /// <summary>The same for the identity of the file, which is only known once its bytes are read.</summary>
    internal Task? ClaimFile(string fileId, out IDisposable? claim) => Take(_files, fileId, out claim);

    private static Task? Take(Dictionary<string, TaskCompletionSource> claims, string key, out IDisposable? claim)
    {
        if (claims.TryGetValue(key, out var held))
        {
            claim = null;
            return held.Task;
        }
        var mine = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        claims[key] = mine;
        claim = new Claim(() =>
        {
            claims.Remove(key);
            mine.SetResult();
        });
        return null;
    }

    private sealed class Claim(Action release) : IDisposable
    {
        private Action? _release = release;

        public void Dispose()
        {
            _release?.Invoke();
            _release = null;
        }
    }
}
