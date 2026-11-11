using System.IO;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.FillSign;

internal enum SavedKind
{
    Signature,
    Initials,
    Stamp,
}

/// <summary>A signature, initials or stamp picture kept for reuse. The kind and the time are in the file name.</summary>
internal sealed record SavedItem(SavedKind Kind, string Path);

/// <summary>Signatures and initials the user keeps, one PNG each in a folder of their own under %APPDATA%\Lazy PDF.</summary>
internal sealed class SavedSignatures(string directory)
{
    public static string DefaultDirectory => System.IO.Path.Combine(StoreFiles.DefaultDirectory, "Signatures");

    public static string StampsDirectory => System.IO.Path.Combine(StoreFiles.DefaultDirectory, "Stamps");

    /// <summary>Newest first.</summary>
    public IReadOnlyList<SavedItem> List(SavedKind kind)
    {
        if (!Directory.Exists(directory)) return [];
        string prefix = kind.ToString().ToLowerInvariant() + "-";
        return
        [
            .. Directory.EnumerateFiles(directory, prefix + "*.png")
                .OrderByDescending(file => System.IO.Path.GetFileName(file), StringComparer.Ordinal)
                .Select(file => new SavedItem(kind, file)),
        ];
    }

    public SavedItem Add(SavedKind kind, PdfRgbaImage image)
    {
        Directory.CreateDirectory(directory);
        string name = $"{kind.ToString().ToLowerInvariant()}-{DateTime.UtcNow:yyyyMMddHHmmssfff}-{Guid.NewGuid().ToString("N")[..6]}.png";
        string path = System.IO.Path.Combine(directory, name);
        File.WriteAllBytes(path, SignatureArt.ToPng(image));
        return new SavedItem(kind, path);
    }

    public PdfRgbaImage? Load(SavedItem item)
    {
        try
        {
            return new WicImageCodec().DecodeFile(File.ReadAllBytes(item.Path))?.FirstOrDefault(f => !f.TooBig);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Remove(SavedItem item)
    {
        try
        {
            File.Delete(item.Path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A file that cannot be deleted stays in the list; there is nothing more to do about it.
        }
    }
}
