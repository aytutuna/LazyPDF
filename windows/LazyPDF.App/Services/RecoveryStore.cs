using System.Text.Json;

namespace LazyPDF.App.Services;

/// <summary>What a recovery file belongs to: the file it was opened from, if any, and when it was last written.</summary>
public sealed class RecoveryMeta
{
    public string Title { get; set; } = "";
    public string? OriginalPath { get; set; }
    public DateTimeOffset Saved { get; set; }

    /// <summary>What the original looked like when it was read, to tell later whether it changed while the copy was kept.</summary>
    public DateTime OriginalWrite { get; set; }
    public long OriginalLength { get; set; }

    /// <summary>The process that wrote the entry; one still running is not a crash.</summary>
    public int ProcessId { get; set; }
}

/// <summary>A document left in the recovery folder.</summary>
public sealed record RecoveryEntry(Guid Id, RecoveryMeta Meta, string PdfPath);

/// <summary>
/// The open documents as they stood after the last edit, in %LOCALAPPDATA%\Lazy PDF\Recovery:
/// id.pdf is the file's bytes, id.json says what it is. A document closed or saved on purpose has
/// no entry, so one still there at the next start is what a crash left.
/// </summary>
public sealed class RecoveryStore(string? directory = null)
{
    private readonly string _directory = directory ?? System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lazy PDF", "Recovery");
    private readonly object _gate = new();
    private readonly Dictionary<Guid, (byte[] Bytes, RecoveryMeta Meta)> _waiting = [];
    private Task _worker = Task.CompletedTask;
    private bool _running;

    /// <summary>Queues the bytes to be written; a newer write for the same document replaces one still waiting.</summary>
    public void Write(Guid id, ReadOnlyMemory<byte> bytes, RecoveryMeta meta)
    {
        lock (_gate)
        {
            _waiting[id] = (bytes.ToArray(), meta);
            if (!_running)
            {
                _running = true;
                _worker = Task.Run(Drain);
            }
        }
    }

    public void Delete(Guid id)
    {
        lock (_gate) _waiting.Remove(id);
        Flush();
        foreach (string extension in new[] { ".pdf", ".json" })
        {
            try { File.Delete(PathOf(id, extension)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>Waits until everything queued is on disk.</summary>
    public void Flush()
    {
        Task worker;
        lock (_gate) worker = _worker;
        worker.Wait();
    }

    public IReadOnlyList<RecoveryEntry> List()
    {
        if (!Directory.Exists(_directory)) return [];
        var entries = new List<RecoveryEntry>();
        foreach (string meta in Directory.EnumerateFiles(_directory, "*.json"))
        {
            string pdf = System.IO.Path.ChangeExtension(meta, ".pdf");
            if (!Guid.TryParse(System.IO.Path.GetFileNameWithoutExtension(meta), out var id) || !File.Exists(pdf)) continue;
            if (StoreFiles.Read<RecoveryMeta>(meta) is { Status: StoreReadStatus.Loaded, Value: { } value })
                entries.Add(new RecoveryEntry(id, value, pdf));
        }
        return [.. entries.OrderByDescending(e => e.Meta.Saved)];
    }

    /// <summary>The entries whose process is gone: what a crash left, as opposed to the documents of an instance that is still open.</summary>
    public IReadOnlyList<RecoveryEntry> Abandoned() => [.. List().Where(e => !IsRunning(e.Meta.ProcessId))];

    private static bool IsRunning(int processId)
    {
        if (processId == 0) return false;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private void Drain()
    {
        while (true)
        {
            Guid id;
            (byte[] Bytes, RecoveryMeta Meta) job;
            lock (_gate)
            {
                if (_waiting.Count == 0)
                {
                    _running = false;
                    return;
                }
                id = _waiting.Keys.First();
                job = _waiting[id];
                _waiting.Remove(id);
            }
            try
            {
                Directory.CreateDirectory(_directory);
                Replace(PathOf(id, ".pdf"), job.Bytes);
                Replace(PathOf(id, ".json"), JsonSerializer.SerializeToUtf8Bytes(job.Meta, StoreFiles.JsonOptions));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Recovery is a courtesy: a full disk must not stop an edit.
            }
        }
    }

    private static void Replace(string path, byte[] bytes)
    {
        string temp = path + ".tmp";
        File.WriteAllBytes(temp, bytes);
        File.Move(temp, path, overwrite: true);
    }

    private string PathOf(Guid id, string extension) => System.IO.Path.Combine(_directory, id.ToString("N") + extension);
}
