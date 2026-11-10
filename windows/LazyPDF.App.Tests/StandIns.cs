using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>A folder of its own for one test, removed with it.</summary>
internal sealed class TempDir : IDisposable
{
    public TempDir() => Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lazypdf-tests-" + Guid.NewGuid().ToString("N"));

    public string Path { get; }

    public string Sub(string name) => System.IO.Path.Combine(Path, name);

    public string File(string name, byte[] bytes)
    {
        Directory.CreateDirectory(Path);
        string file = Sub(name);
        System.IO.File.WriteAllBytes(file, bytes);
        return file;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// <summary>Draws nothing: blank pages of a fixed size, and a count of how often the file was read.</summary>
internal sealed class FakeRenderer : IDocumentRenderer
{
    public int Loads { get; private set; }
    public bool Draws { get; set; } = true;
    public bool Disposed { get; private set; }

    public bool Load(PdfEditSession session, string? password)
    {
        Loads++;
        return Draws;
    }

    public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

    public PdfRgbaImage? Render(int pageIndex, double dpi) =>
        Draws ? new PdfRgbaImage(4, 6, Enumerable.Repeat((byte)255, 4 * 6 * 4).ToArray()) : null;

    public void Dispose() => Disposed = true;
}

/// <summary>Takes pictures as 4 by 4 grey squares, one frame each.</summary>
internal sealed class FakeCodec : IImageCodec
{
    public PdfRgbaImage? Decode(byte[] data, string codec) => null;

    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) =>
        file.Length == 0 ? null : [new PdfRgbaImage(4, 4, Enumerable.Repeat((byte)128, 4 * 4 * 4).ToArray())];

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
}

internal sealed class FakeFonts : IFontSource
{
    public FontFile? Find(string family, FontStyles style) => null;
}

internal sealed class FakeSisters : ISisterApps
{
    public bool LazyScanInstalled { get; set; }
    public bool LazyPrintInstalled { get; set; }
    public bool PrintTaken { get; set; }
    public List<string> Printed { get; } = [];
    public int ScanOpened { get; private set; }

    public void OpenLazyScan() => ScanOpened++;

    public bool TryPrint(string path)
    {
        Printed.Add(path);
        return PrintTaken;
    }
}

/// <summary>The view model with fakes for the system, and folders of its own for what it writes.</summary>
internal sealed class ViewModelFixture : IDisposable
{
    public ViewModelFixture()
    {
        Dir = new TempDir();
        Vm = new AppViewModel(() => NewRenderer(), new FakeCodec(), new FakeFonts(), Sisters,
                              Dir.Sub("settings"), Dir.Sub("recovery"), Dir.Sub("print"));
    }

    public TempDir Dir { get; }
    public FakeSisters Sisters { get; } = new();
    public AppViewModel Vm { get; }
    public List<FakeRenderer> Renderers { get; } = [];

    /// <summary>Whether a renderer made from now on can draw.</summary>
    public bool Draws { get; set; } = true;

    private FakeRenderer NewRenderer()
    {
        var renderer = new FakeRenderer { Draws = Draws };
        Renderers.Add(renderer);
        return renderer;
    }

    public string Pdf(string name = "a.pdf", int pages = 1) => Dir.File(name, Pdfs.Text(pages));

    public void Dispose() => Dir.Dispose();
}

/// <summary>PDFs for the tests, built by Core.</summary>
internal static class Pdfs
{
    public static byte[] Text(int pages = 1, string line = "Hello from the tests.")
    {
        var text = string.Join("\f", Enumerable.Range(0, pages).Select(p => $"{line} Page {p + 1}."));
        return PdfFromText.Create(text, new FakeFonts()).Bytes;
    }

    /// <summary>A file whose owner password is "owner" and that allows only <paramref name="allowed"/> to anyone else.</summary>
    public static byte[] Restricted(PdfPermissions allowed, PdfCryptStrength strength = PdfCryptStrength.Aes256)
    {
        var document = PdfDocument.Open(Text());
        var security = PdfSecurity.Create("", "owner", allowed, strength, document.FirstId ?? []);
        return document.SaveRewrite(new PdfSaveOptions(Security: security));
    }

    /// <summary>The file of the fixtures (Tests/Fixtures/Documents) by name.</summary>
    public static string Fixture(string name) => System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", "Documents", name);

    /// <summary>Changes the title, so the session has something to commit.</summary>
    public static void Retitle(PdfEditSession session, string title)
    {
        var metadata = DocumentMetadata.Read(session.Document);
        (metadata with { Title = title }).Write(session.Document);
    }
}
