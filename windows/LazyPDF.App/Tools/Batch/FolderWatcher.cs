namespace LazyPDF.App.Tools.Batch;

/// <summary>
/// Reports each PDF that appears in a folder once it can be opened: a file that is still being copied is tried
/// again until its writer lets go. Files already there are not reported. Events are raised on a pool thread.
/// </summary>
internal sealed class FolderWatcher : IDisposable
{
    private readonly FileSystemWatcher _watcher;
    private readonly HashSet<string> _waiting = [];
    private readonly Timer _timer;
    private readonly TimeSpan _delay;
    private bool _disposed;

    public FolderWatcher(string folder, TimeSpan? delay = null)
    {
        _delay = delay ?? TimeSpan.FromSeconds(1.5);
        _timer = new Timer(_ => Check());
        _watcher = new FileSystemWatcher(folder, "*.pdf")
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            InternalBufferSize = 64 * 1024,
        };
        _watcher.Created += Watcher_Changed;
        _watcher.Renamed += Watcher_Changed;
        _watcher.Changed += Watcher_Changed;
        _watcher.Error += Watcher_Error;
        _watcher.EnableRaisingEvents = true;
    }

    public event Action<string>? Found;

    /// <summary>The folder went away or events were lost; the watcher has stopped being able to say what appeared.</summary>
    public event Action? Failed;

    private void Watcher_Changed(object sender, FileSystemEventArgs e)
    {
        lock (_waiting)
        {
            if (_disposed) return;
            _waiting.Add(e.FullPath);
            _timer.Change(_delay, Timeout.InfiniteTimeSpan);
        }
    }

    private void Watcher_Error(object sender, ErrorEventArgs e) => Failed?.Invoke();

    private void Check()
    {
        List<string> ready = [];
        lock (_waiting)
        {
            if (_disposed) return;
            foreach (var path in _waiting.ToList())
            {
                if (!File.Exists(path)) _waiting.Remove(path);
                else if (CanOpen(path))
                {
                    _waiting.Remove(path);
                    ready.Add(path);
                }
            }
            if (_waiting.Count > 0) _timer.Change(_delay, Timeout.InfiniteTimeSpan);
        }
        foreach (var path in ready)
        {
            if (_disposed) return;
            Found?.Invoke(path);
        }
    }

    private static bool CanOpen(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
            return stream.Length > 0;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        _watcher.Dispose();
        lock (_waiting)
        {
            _disposed = true;
            _timer.Dispose();
        }
    }
}
