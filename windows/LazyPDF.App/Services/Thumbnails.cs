using System.Security.Cryptography;
using System.Text;
using System.Windows.Media.Imaging;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// Pictures of the first page of the files on the Home tab, kept as PNGs in %LOCALAPPDATA%\Lazy PDF\Thumbnails
/// under a name made from the file's path, size and time, so a changed file gets a new one.
/// </summary>
public sealed class Thumbnails
{
    private static readonly TimeSpan KeepFor = TimeSpan.FromDays(60);
    private static readonly SemaphoreSlim Drawing = new(2);

    internal static long MaxFileBytes = 64L * 1024 * 1024;

    private readonly Func<IDocumentRenderer> _renderers;
    private readonly string _directory;
    private readonly HashSet<string> _encrypted = [];
    private int _generation;

    public Thumbnails(Func<IDocumentRenderer> renderers, string? directory = null)
    {
        _renderers = renderers;
        _directory = directory ?? AppFolders.Thumbnails;
        Prune();
    }

    /// <summary>The PNG of the first page, <paramref name="width"/> pixels wide; null when the file cannot be opened without a password or drawn.</summary>
    public async Task<byte[]?> GetAsync(string path, int width = 224)
    {
        var info = await Task.Run(() => new FileInfo(path) is { Exists: true } file ? file : null);
        if (info is null) return null;
        string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{info.FullName}|{info.Length}|{info.LastWriteTimeUtc.Ticks}|{width}")))[..32];
        string cached = System.IO.Path.Combine(_directory, $"{PathHash(info.FullName)}-{key}.png");
        try
        {
            if (File.Exists(cached))
            {
                File.SetLastWriteTimeUtc(cached, DateTime.UtcNow);
                return await File.ReadAllBytesAsync(cached);
            }
            if (info.Length > MaxFileBytes) return null;
            string name = System.IO.Path.GetFileName(cached);
            lock (_encrypted)
            {
                if (_encrypted.Contains(name)) return null;
            }
            int generation = _generation;
            // Two draws stuck on a dead share must not hold back every other card for the session.
            if (!await Drawing.WaitAsync(TimeSpan.FromSeconds(20))) return null;
            byte[]? png;
            try
            {
                // The list was rebuilt while this waited: its cards ask again, so drawing here only delays them.
                if (generation != _generation) return null;
                if (File.Exists(cached)) return await File.ReadAllBytesAsync(cached);
                bool encrypted;
                (png, encrypted) = await Task.Run(() => Draw(path, width));
                if (encrypted)
                {
                    lock (_encrypted)
                    {
                        _encrypted.Add(name);
                    }
                }
            }
            finally
            {
                Drawing.Release();
            }
            // Cleared or forgotten while it drew: the card is gone, so no picture is kept.
            if (png is not null && generation == _generation)
            {
                Directory.CreateDirectory(_directory);
                await File.WriteAllBytesAsync(cached, png);
            }
            return png;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Forget(string path)
    {
        Interlocked.Increment(ref _generation);
        string hash = PathHash(new FileInfo(path).FullName);
        lock (_encrypted)
        {
            _encrypted.RemoveWhere(name => name.StartsWith(hash, StringComparison.Ordinal));
        }
        Delete($"{hash}-*.png");
    }

    public void Clear()
    {
        Interlocked.Increment(ref _generation);
        lock (_encrypted)
        {
            _encrypted.Clear();
        }
        Delete("*.png");
    }

    private static string PathHash(string fullName) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(fullName.ToUpperInvariant())))[..16];

    private void Delete(string pattern)
    {
        try
        {
            foreach (string file in Directory.EnumerateFiles(_directory, pattern))
            {
                try
                {
                    File.Delete(file);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
    }

    private (byte[]? Png, bool Encrypted) Draw(string path, int width)
    {
        try
        {
            var session = PdfEditSession.Open(path);
            using var renderer = _renderers();
            if (session.Document.IsEncrypted) return (null, true);
            if (!renderer.Load(session, null)) return (null, false);
            var (pointsWide, _) = renderer.PageSize(0);
            if (renderer.Render(0, width / (pointsWide / 72)) is not { } image) return (null, false);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(Pixels.ToBitmap(image)));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return (stream.ToArray(), false);
        }
        catch (Exception e) when (e is PdfReadException or IOException or UnauthorizedAccessException)
        {
            return (null, false);
        }
    }

    private void Prune()
    {
        if (!Directory.Exists(_directory)) return;
        foreach (string file in Directory.EnumerateFiles(_directory, "*.png"))
        {
            try
            {
                if (DateTime.UtcNow - File.GetLastWriteTimeUtc(file) > KeepFor) File.Delete(file);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}
