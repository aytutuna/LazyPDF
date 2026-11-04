namespace LazyPDF.App.Services;

/// <summary>A file in the recent list: where it is and when it was last opened.</summary>
public sealed class RecentFile
{
    public string Path { get; set; } = "";
    public DateTimeOffset Opened { get; set; }
}

/// <summary>recent.json's content.</summary>
public sealed class RecentList
{
    public List<RecentFile> Files { get; set; } = [];
}

/// <summary>The files opened last, newest first, in recent.json beside the preferences.</summary>
public sealed class RecentFiles(string? directory = null)
{
    public const int Limit = 24;

    private readonly string _path = System.IO.Path.Combine(directory ?? StoreFiles.DefaultDirectory, "recent.json");

    public IReadOnlyList<RecentFile> Load() =>
        [.. (StoreFiles.Load<RecentList>(_path)?.Files ?? []).Where(f => f.Path.Length > 0).Take(Limit)];

    public void Add(string path, DateTimeOffset? now = null)
    {
        string full = System.IO.Path.GetFullPath(path);
        var files = Load().Where(f => !string.Equals(f.Path, full, StringComparison.OrdinalIgnoreCase)).ToList();
        files.Insert(0, new RecentFile { Path = full, Opened = now ?? DateTimeOffset.Now });
        StoreFiles.Write(new RecentList { Files = [.. files.Take(Limit)] }, _path);
    }

    public void Remove(string path)
    {
        var files = Load().Where(f => !string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase)).ToList();
        StoreFiles.Write(new RecentList { Files = files }, _path);
    }

    public void Clear() => StoreFiles.Write(new RecentList(), _path);
}
