using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using LazyPDF.Core;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using WinPdf = Windows.Data.Pdf;

namespace LazyPDF.App.Services;

/// <summary>
/// The pages of one document drawn by Windows.Data.Pdf, as the probe of its behaviour found it:
/// the bytes go in through an InMemoryRandomAccessStream and are loaded again after every commit, the
/// output is a BMP whose 54-byte header is read directly, and a size asked for is rounded to what
/// the system reaches (<see cref="Reachable"/>).
/// </summary>
/// <remarks>
/// A file the system cannot open (AES-256 revision 6, public-key encryption, a password it refuses)
/// is decrypted by the engine first. Safe to call from any thread; <see cref="Load"/> replaces the
/// document and pages already being drawn finish on the old one.
/// </remarks>
public sealed class WindowsPageRenderer : IDocumentRenderer
{
    // Windows turns a requested size of 1 into this many pixels (1.4 on the machine that was probed), whatever
    // the display's scale, so it is measured once on a real page.
    private static double? s_scale;

    private const double DipPerPoint = 4.0 / 3.0;
    private const long MaxPixels = 150_000_000;

    private static readonly Guid Bmp = BitmapEncoder.BmpEncoderId;

    // The sizes are in the units the viewer lays out (/UserUnit applied, which the system ignores); Units says by how much.
    // A load that was replaced is let go of once the pictures still being drawn from it are done.
    private sealed class Loaded(WinPdf.PdfDocument document, InMemoryRandomAccessStream stream, (double Width, double Height)[] sizes, double[] units)
    {
        private readonly object _gate = new();
        private int _users;
        private bool _retired;
        private bool _disposed;

        public WinPdf.PdfDocument Document { get; } = document;
        public (double Width, double Height)[] Sizes { get; } = sizes;
        public double[] Units { get; } = units;

        public Loaded With((double Width, double Height)[] shown, double[] units) => new(Document, stream, shown, units);

        public bool Enter()
        {
            lock (_gate)
            {
                if (_disposed) return false;
                _users++;
                return true;
            }
        }

        public void Exit()
        {
            lock (_gate)
            {
                _users--;
                Release();
            }
        }

        public void Retire()
        {
            lock (_gate)
            {
                _retired = true;
                Release();
            }
        }

        private void Release()
        {
            if (!_retired || _users > 0 || _disposed) return;
            _disposed = true;
            stream.Dispose();
        }
    }

    private volatile Loaded? _loaded;
    private volatile bool _disposed;

    /// <summary>Pixels the system makes of one unit of a requested size; 1.4 until a document has been loaded.</summary>
    public static double Scale => s_scale ?? 1.4;

    public int PageCount => _loaded?.Sizes.Length ?? 0;

    public (double Width, double Height) PageSize(int pageIndex) =>
        _loaded is { } loaded && (uint)pageIndex < loaded.Sizes.Length ? loaded.Sizes[pageIndex] : (0, 0);

    /// <summary>The size nearest <paramref name="pixels"/> that the system can produce.</summary>
    public static int Reachable(int pixels) => Output(Request(pixels));

    private static int Request(double pixels) => (int)Math.Max(1, Math.Round(pixels / Scale));

    private static int Output(int requested) => (int)Math.Round(requested * Scale);

    public bool Load(PdfEditSession session, string? password)
    {
        // The facts are taken here, on the calling thread; only the opening runs on the pool.
        var document = session.Document;
        var current = session.Current;
        var units = UnitsOf(document);
        return Task.Run(() => OpenAsync(current, units, document.IsEncrypted ? document : null, password)).GetAwaiter().GetResult();
    }

    /// <summary>
    /// Like <see cref="Load"/> but the file is opened without holding the calling thread, so the session may be edited meanwhile.
    /// An encrypted document is read on the calling thread, since the engine's copy of it needs the live document.
    /// </summary>
    public Task<bool> LoadAsync(PdfEditSession session, string? password)
    {
        if (session.Document.IsEncrypted) return Task.FromResult(Load(session, password));
        return OpenAsync(session.Current, UnitsOf(session.Document), null, password);
    }

    private static double[] UnitsOf(PdfDocument document) => [.. document.Pages.Select(p => p.UserUnit)];

    // The document is given only when it is encrypted, and then the caller waits for the result.
    private async Task<bool> OpenAsync(ReadOnlyMemory<byte> current, double[] units, PdfDocument? encrypted, string? password)
    {
        if (encrypted is null || encrypted.Security is { IsPublicKey: false, Revision: < 6 })
        {
            if (await TryOpenAsync(current, password) is { } direct) return Accept(direct, units);
        }
        if (encrypted is not null)
        {
            try
            {
                // Only for drawing: the copy is never saved, so the permissions on changing the encryption do not apply.
                return Accept(await TryOpenAsync(new PdfRewriter(encrypted, new PdfSaveOptions()).Run(), null), units);
            }
            catch (PdfReadException)
            {
                // The engine cannot rewrite it; the page stays undrawn.
            }
        }
        return Accept(null, units);
    }

    private bool Accept(Loaded? loaded, double[] pageUnits)
    {
        if (_disposed)
        {
            loaded?.Retire();
            return false;
        }
        if (loaded is not null)
        {
            var units = new double[loaded.Sizes.Length];
            for (int i = 0; i < units.Length; i++) units[i] = i < pageUnits.Length ? pageUnits[i] : 1;
            loaded = loaded.With([.. loaded.Sizes.Select((s, i) => (s.Width * units[i], s.Height * units[i]))], units);
        }
        Interlocked.Exchange(ref _loaded, loaded)?.Retire();
        return loaded is not null;
    }

    private double UnitOf(int pageIndex) => _loaded is { } loaded && (uint)pageIndex < loaded.Units.Length ? loaded.Units[pageIndex] : 1;

    private static async Task<Loaded?> TryOpenAsync(ReadOnlyMemory<byte> bytes, string? password)
    {
        var stream = new InMemoryRandomAccessStream();
        try
        {
            await stream.WriteAsync(bytes.ToArray().AsBuffer());
            stream.Seek(0);
            var document = password is { Length: > 0 }
                ? await WinPdf.PdfDocument.LoadFromStreamAsync(stream, password)
                : await WinPdf.PdfDocument.LoadFromStreamAsync(stream);
            var sizes = new (double, double)[document.PageCount];
            for (uint i = 0; i < sizes.Length; i++)
            {
                using var page = document.GetPage(i);
                sizes[i] = (page.Size.Width / DipPerPoint, page.Size.Height / DipPerPoint);
            }
            if (sizes.Length > 0) s_scale ??= await MeasureScaleAsync(document);
            return new Loaded(document, stream, sizes, new double[sizes.Length]);
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException or ArithmeticException)
        {
            stream.Dispose();
            return null;
        }
    }

    private static async Task<double> MeasureScaleAsync(WinPdf.PdfDocument document)
    {
        // A square corner at a fixed size, so the page's own shape cannot make the picture too big to build.
        using var page = document.GetPage(0);
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new WinPdf.PdfPageRenderOptions
        {
            SourceRect = new Rect(0, 0, 10, 10),
            DestinationWidth = 100,
            DestinationHeight = 100,
            BitmapEncoderId = Bmp,
        });
        var (width, _, _) = await ReadBmpAsync(stream);
        return width / 100.0;
    }

    public PdfRgbaImage? Render(int pageIndex, double dpi) =>
        Task.Run(() => RenderAsync(pageIndex, dpi)).GetAwaiter().GetResult();

    /// <summary>The page at <paramref name="dpi"/>; the width is the nearest the system reaches.</summary>
    public async Task<PdfRgbaImage?> RenderAsync(int pageIndex, double dpi)
    {
        var (width, height) = PageSize(pageIndex);
        if (width <= 0 || dpi <= 0) return null;
        int requested = Request(width * dpi / 72);
        var options = new WinPdf.PdfPageRenderOptions { DestinationWidth = (uint)requested, BitmapEncoderId = Bmp };
        long pixels = (long)Output(requested) * Math.Max(1, Output(Request(width * dpi / 72 * height / width)));
        return await DrawAsync(pageIndex, options, pixels);
    }

    /// <summary>
    /// A rectangle of the page, in points of the displayed page with the origin at its top left, drawn
    /// at <paramref name="dpi"/>. Outside the page it is white.
    /// </summary>
    public async Task<PdfRgbaImage?> RenderRegionAsync(int pageIndex, DisplayRect region, double dpi)
    {
        if (region.Width <= 0 || region.Height <= 0 || dpi <= 0) return null;
        double pixelsPerPoint = dpi / 72;
        return await DrawAsync(pageIndex, Region(UnitOf(pageIndex), region.X, region.Y, region.Width, region.Height,
            Request(region.Width * pixelsPerPoint), Request(region.Height * pixelsPerPoint)));
    }

    /// <summary>
    /// A tile of the page drawn whole at <paramref name="pixelsPerPoint"/>: the rectangle at
    /// (<paramref name="x"/>, <paramref name="y"/>) of <paramref name="width"/> by <paramref name="height"/> pixels in
    /// the pixels of the whole page at that scale. A size the system cannot produce is cut down to the nearest it
    /// can (<see cref="Reachable"/>), so step to the next tile by the size of the image given back; tiles
    /// made this way meet exactly.
    /// </summary>
    public async Task<PdfRgbaImage?> RenderTileAsync(int pageIndex, double pixelsPerPoint, int x, int y, int width, int height)
    {
        if (width <= 0 || height <= 0 || pixelsPerPoint <= 0) return null;
        int w = Reachable(width), h = Reachable(height);
        return await DrawAsync(pageIndex, Region(UnitOf(pageIndex), x / pixelsPerPoint, y / pixelsPerPoint, w / pixelsPerPoint, h / pixelsPerPoint, Request(w), Request(h)));
    }

    // The system draws a page of /UserUnit 2 at the size of /UserUnit 1, so a region given in the viewer's units is cut down by the unit.
    private static WinPdf.PdfPageRenderOptions Region(double unit, double x, double y, double width, double height, int requestedWidth, int requestedHeight) => new()
    {
        SourceRect = new Rect(x / unit * DipPerPoint, y / unit * DipPerPoint, width / unit * DipPerPoint, height / unit * DipPerPoint),
        DestinationWidth = (uint)requestedWidth,
        DestinationHeight = (uint)requestedHeight,
        BitmapEncoderId = Bmp,
    };

    // pixels is the size of the picture when the height is left to the system.
    private async Task<PdfRgbaImage?> DrawAsync(int pageIndex, WinPdf.PdfPageRenderOptions options, long? pixels = null)
    {
        if (_loaded is not { } loaded || (uint)pageIndex >= loaded.Sizes.Length) return null;
        pixels ??= (long)Output((int)options.DestinationWidth) * Math.Max(1, Output((int)options.DestinationHeight));
        if (pixels > MaxPixels || !loaded.Enter()) return null;
        try
        {
            using var page = loaded.Document.GetPage((uint)pageIndex);
            using var stream = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(stream, options);
            var (width, height, rgba) = await ReadBmpAsync(stream);
            return new PdfRgbaImage(width, height, rgba);
        }
        catch (Exception e) when (e is COMException or ArithmeticException or OutOfMemoryException or InvalidDataException or ObjectDisposedException)
        {
            return null;
        }
        finally
        {
            loaded.Exit();
        }
    }

    // 32 bits per pixel, B G R A with straight alpha, rows from the bottom; the data starts where the header says.
    internal static async Task<(int Width, int Height, byte[] Rgba)> ReadBmpAsync(InMemoryRandomAccessStream stream)
    {
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return ParseBmp(bytes);
    }

    internal static (int Width, int Height, byte[] Rgba) ParseBmp(byte[] bytes)
    {
        if (bytes.Length < 54 || bytes[0] != 'B' || bytes[1] != 'M') throw new InvalidDataException("Not a bitmap.");
        int offset = BitConverter.ToInt32(bytes, 10);
        int width = BitConverter.ToInt32(bytes, 18);
        int rawHeight = BitConverter.ToInt32(bytes, 22);
        int height = Math.Abs(rawHeight);
        if (BitConverter.ToInt16(bytes, 28) != 32 || width <= 0 || height == 0 || offset + (long)width * height * 4 > bytes.Length)
            throw new InvalidDataException("Not a 32-bit bitmap.");
        var rgba = new byte[width * height * 4];
        int stride = width * 4;
        for (int y = 0; y < height; y++)
        {
            var from = bytes.AsSpan(offset + (rawHeight > 0 ? height - 1 - y : y) * stride, stride);
            var to = rgba.AsSpan(y * stride, stride);
            for (int i = 0; i < stride; i += 4)
            {
                to[i] = from[i + 2];
                to[i + 1] = from[i + 1];
                to[i + 2] = from[i];
                to[i + 3] = from[i + 3];
            }
        }
        return (width, height, rgba);
    }

    public void Dispose()
    {
        _disposed = true;
        Interlocked.Exchange(ref _loaded, null)?.Retire();
    }
}
