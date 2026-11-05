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

    private readonly Func<IDocumentRenderer> _renderers;
    private readonly string _directory;

    public Thumbnails(Func<IDocumentRenderer> renderers, string? directory = null)
    {
        _renderers = renderers;
        _directory = directory ?? AppFolders.Thumbnails;
        Prune();
    }

    /// <summary>The PNG of the first page, <paramref name="width"/> pixels wide; null when the file cannot be opened without a password or drawn.</summary>
    public async Task<byte[]?> GetAsync(string path, int width = 224)
    {
        var info = new FileInfo(path);
        if (!info.Exists) return null;
        string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{info.FullName}|{info.Length}|{info.LastWriteTimeUtc.Ticks}|{width}")))[..32];
        string cached = System.IO.Path.Combine(_directory, key + ".png");
        try
        {
            if (File.Exists(cached)) return await File.ReadAllBytesAsync(cached);
            byte[]? png = await Task.Run(() => Draw(path, width));
            if (png is not null)
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

    private byte[]? Draw(string path, int width)
    {
        try
        {
            var session = PdfEditSession.Open(path);
            using var renderer = _renderers();
            if (!renderer.Load(session, null)) return null;
            var (pointsWide, _) = renderer.PageSize(0);
            if (renderer.Render(0, width / (pointsWide / 72)) is not { } image) return null;
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(Pixels.ToBitmap(image)));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }
        catch (Exception e) when (e is PdfReadException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void Prune()
    {
        if (!Directory.Exists(_directory)) return;
        foreach (string file in Directory.EnumerateFiles(_directory, "*.png"))
        {
            try
            {
                if (DateTime.UtcNow - File.GetLastAccessTimeUtc(file) > KeepFor) File.Delete(file);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}
