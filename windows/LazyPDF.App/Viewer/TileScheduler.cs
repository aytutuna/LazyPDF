using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// Draws wanted tiles a few at a time, lowest priority number first. Each <see cref="Want"/> replaces the
/// whole list: what is no longer in it is dropped from the queue, or, if already being drawn, finished and
/// thrown away, so tiles that scrolled out of reach cost nothing but the one in flight.
/// </summary>
public sealed class TileScheduler : IDisposable
{
    private sealed class Entry(TileSpec spec, double priority)
    {
        public TileSpec Spec { get; } = spec;
        public double Priority { get; set; } = priority;
        public bool Running { get; set; }
        public bool Dropped { get; set; }
    }

    private readonly object _gate = new();
    private readonly Dictionary<TileKey, Entry> _entries = [];
    private readonly Func<TileSpec, Task<PdfRgbaImage?>> _render;
    private readonly Action<TileSpec, PdfRgbaImage?> _done;
    private readonly SemaphoreSlim _signal = new(0);
    private readonly CancellationTokenSource _stop = new();

    /// <param name="render">Draws one tile; may be called from several threads at once.</param>
    /// <param name="done">Gets each finished tile (null when it could not be drawn) on a worker thread.</param>
    public TileScheduler(Func<TileSpec, Task<PdfRgbaImage?>> render, Action<TileSpec, PdfRgbaImage?> done, int workers = 3)
    {
        _render = render;
        _done = done;
        for (int i = 0; i < workers; i++) _ = Task.Run(WorkAsync);
    }

    /// <summary>Tiles waiting for a worker.</summary>
    public int Queued
    {
        get
        {
            lock (_gate) return _entries.Values.Count(e => !e.Running);
        }
    }

    /// <summary>Tiles being drawn and tiles waiting.</summary>
    public int Pending
    {
        get
        {
            lock (_gate) return _entries.Values.Count(e => !e.Dropped);
        }
    }

    /// <summary>Makes <paramref name="wanted"/> the work to do; a lower priority number is drawn sooner.</summary>
    public void Want(IReadOnlyList<(TileSpec Spec, double Priority)> wanted)
    {
        int added = 0;
        lock (_gate)
        {
            var keep = wanted.Select(w => w.Spec.Key).ToHashSet();
            foreach (var entry in _entries.Values.ToList())
            {
                if (keep.Contains(entry.Spec.Key)) continue;
                if (entry.Running) entry.Dropped = true;
                else _entries.Remove(entry.Spec.Key);
            }
            foreach (var (spec, priority) in wanted)
            {
                if (_entries.TryGetValue(spec.Key, out var entry))
                {
                    entry.Priority = priority;
                    entry.Dropped = false;
                }
                else
                {
                    _entries[spec.Key] = new Entry(spec, priority);
                    added++;
                }
            }
        }
        if (added > 0) _signal.Release(added);
    }

    private async Task WorkAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                await _signal.WaitAsync(_stop.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            Entry? next;
            lock (_gate)
            {
                next = null;
                foreach (var entry in _entries.Values)
                {
                    if (!entry.Running && (next is null || entry.Priority < next.Priority)) next = entry;
                }
                if (next is not null) next.Running = true;
            }
            if (next is null) continue;

            PdfRgbaImage? image = null;
            try
            {
                image = await _render(next.Spec);
            }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                System.Diagnostics.Trace.TraceError(e.ToString());
            }
            bool dropped;
            lock (_gate)
            {
                dropped = next.Dropped;
                if (_entries.TryGetValue(next.Spec.Key, out var current) && ReferenceEquals(current, next)) _entries.Remove(next.Spec.Key);
            }
            if (!dropped && !_stop.IsCancellationRequested) _done(next.Spec, image);
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        lock (_gate) _entries.Clear();
    }
}
