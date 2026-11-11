namespace LazyPDF.App.Services;

/// <summary>A file in the recent list: where it is and when it was last opened.</summary>
public sealed class RecentFile
{
    public string Path { get; set; } = "";
    public DateTimeOffset Opened { get; set; }

    /// <summary>Where the file was left: the page (0-based), the zoom (0 for none) and the fit mode.</summary>
    public int Page { get; set; }
    public double Zoom { get; set; }
    public int Fit { get; set; }
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
        var all = Load();
        var kept = all.FirstOrDefault(f => string.Equals(f.Path, full, StringComparison.OrdinalIgnoreCase));
        var files = all.Where(f => !ReferenceEquals(f, kept)).ToList();
        files.Insert(0, new RecentFile { Path = full, Opened = now ?? DateTimeOffset.Now, Page = kept?.Page ?? 0, Zoom = kept?.Zoom ?? 0, Fit = kept?.Fit ?? 0 });
        StoreFiles.Write(new RecentList { Files = [.. files.Take(Limit)] }, _path);
    }

    public void RememberView(string path, int page, double zoom, int fit)
    {
        var files = Load().ToList();
        if (files.FirstOrDefault(f => string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase)) is not { } file) return;
        file.Page = page;
        file.Zoom = zoom;
        file.Fit = fit;
        StoreFiles.Write(new RecentList { Files = files }, _path);
    }

    public void Remove(string path)
    {
        var files = Load().Where(f => !string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase)).ToList();
        StoreFiles.Write(new RecentList { Files = files }, _path);
    }

    public void Clear() => StoreFiles.Write(new RecentList(), _path);
}
