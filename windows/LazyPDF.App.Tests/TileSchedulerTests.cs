using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The queue of tiles to draw: nearest first, dropped when wanted no more.
public sealed class TileSchedulerTests
{
    private static TileSpec Tile(int page) => new(new TileKey(page, 0, 1, 0, 0, PageTint.None), 0, 0, 4, 4);

    private static readonly PdfRgbaImage Image = new(1, 1, [0, 0, 0, 255]);

    // A renderer that holds every tile until the test lets it go.
    private sealed class Gate
    {
        private readonly object _lock = new();
        private readonly List<(TileSpec Spec, TaskCompletionSource<PdfRgbaImage?> Done)> _started = [];

        public List<int> Started
        {
            get
            {
                lock (_lock) return [.. _started.Select(s => s.Spec.Key.Page)];
            }
        }

        public Task<PdfRgbaImage?> Render(TileSpec spec)
        {
            var done = new TaskCompletionSource<PdfRgbaImage?>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_lock) _started.Add((spec, done));
            return done.Task;
        }

        public void Finish(int page)
        {
            lock (_lock) _started.First(s => s.Spec.Key.Page == page).Done.SetResult(Image);
        }
    }

    private static async Task Until(Func<bool> condition)
    {
        for (int i = 0; i < 200 && !condition(); i++) await Task.Delay(10);
        Assert.True(condition());
    }

    [Fact]
    public async Task TheLowestPriorityNumberIsDrawnFirst()
    {
        var gate = new Gate();
        using var scheduler = new TileScheduler(gate.Render, (_, _) => { }, workers: 1);

        scheduler.Want([(Tile(1), 30), (Tile(2), 10), (Tile(3), 20)]);
        await Until(() => gate.Started.Count == 1);
        gate.Finish(2);
        await Until(() => gate.Started.Count == 2);
        gate.Finish(3);
        await Until(() => gate.Started.Count == 3);

        Assert.Equal([2, 3, 1], gate.Started);
    }

    [Fact]
    public async Task WhatIsNotWantedAnyMoreIsNeverDrawn()
    {
        var gate = new Gate();
        using var scheduler = new TileScheduler(gate.Render, (_, _) => { }, workers: 1);
        scheduler.Want([(Tile(1), 1), (Tile(2), 2), (Tile(3), 3)]);
        await Until(() => gate.Started.Count == 1);

        scheduler.Want([(Tile(3), 1)]);
        gate.Finish(1);
        await Until(() => gate.Started.Count == 2);

        Assert.Equal([1, 3], gate.Started);
    }

    [Fact]
    public async Task ATileBeingDrawnWhenItIsDroppedIsFinishedButNotDelivered()
    {
        var gate = new Gate();
        var delivered = new List<int>();
        using var scheduler = new TileScheduler(gate.Render, (spec, _) => { lock (delivered) delivered.Add(spec.Key.Page); }, workers: 1);
        scheduler.Want([(Tile(1), 1), (Tile(2), 2)]);
        await Until(() => gate.Started.Count == 1);

        scheduler.Want([(Tile(2), 1)]);
        gate.Finish(1);
        await Until(() => gate.Started.Count == 2);
        gate.Finish(2);
        await Until(() => scheduler.Pending == 0);
        await Task.Delay(50);

        lock (delivered) Assert.Equal([2], delivered);
    }

    [Fact]
    public async Task ATileWantedAgainWhileBeingDrawnIsStillDelivered()
    {
        var gate = new Gate();
        var delivered = new List<int>();
        using var scheduler = new TileScheduler(gate.Render, (spec, _) => { lock (delivered) delivered.Add(spec.Key.Page); }, workers: 1);
        scheduler.Want([(Tile(1), 1)]);
        await Until(() => gate.Started.Count == 1);
        scheduler.Want([]);

        scheduler.Want([(Tile(1), 1)]);
        gate.Finish(1);
        await Until(() => { lock (delivered) return delivered.Count == 1; });

        Assert.Single(gate.Started);
    }

    [Fact]
    public async Task SeveralWorkersDrawAtTheSameTime()
    {
        var gate = new Gate();
        using var scheduler = new TileScheduler(gate.Render, (_, _) => { }, workers: 3);

        scheduler.Want([(Tile(1), 1), (Tile(2), 2), (Tile(3), 3), (Tile(4), 4)]);

        await Until(() => gate.Started.Count == 3);
        await Task.Delay(50);
        Assert.Equal(3, gate.Started.Count);
        Assert.Equal(1, scheduler.Queued);
    }

    [Fact]
    public async Task ATileThatCannotBeDrawnIsDeliveredAsNull()
    {
        var result = new TaskCompletionSource<PdfRgbaImage?>();
        using var scheduler = new TileScheduler(_ => Task.FromResult<PdfRgbaImage?>(null), (_, image) => result.TrySetResult(image), workers: 1);

        scheduler.Want([(Tile(1), 1)]);

        Assert.Null(await result.Task.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task ARendererThatThrowsDoesNotStopTheWorker()
    {
        var delivered = new TaskCompletionSource<int>();
        using var scheduler = new TileScheduler(
            spec => spec.Key.Page == 1 ? throw new InvalidOperationException("broken") : Task.FromResult<PdfRgbaImage?>(Image),
            (spec, _) => { if (spec.Key.Page == 2) delivered.TrySetResult(2); },
            workers: 1);

        scheduler.Want([(Tile(1), 1), (Tile(2), 2)]);

        Assert.Equal(2, await delivered.Task.WaitAsync(TimeSpan.FromSeconds(5)));
    }
}
