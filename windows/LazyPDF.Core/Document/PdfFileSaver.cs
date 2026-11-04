using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

// Global rule 5: a save goes to a temporary file in the same folder, is read back, and only then
// takes the original's place. The replacement follows Lazy Scan's PdfAppender.cs (ReplaceOriginal).

/// <summary>Writes PDF bytes to a path without ever leaving a half-written file there.</summary>
public static class PdfFileSaver
{
    /// <summary>
    /// Writes <paramref name="bytes"/> to a hidden temporary file beside <paramref name="path"/>,
    /// reads it back, opens it with <see cref="PdfDocument.Open(byte[], string?)"/>
    /// (<paramref name="password"/> for an encrypted one) and then replaces the file, keeping its
    /// attributes and creation time. Any failure removes the temporary file and leaves the original
    /// as it was. Throws <see cref="IOException"/>, <see cref="UnauthorizedAccessException"/> or
    /// <see cref="PdfReadException"/> (the bytes are not a PDF).
    /// </summary>
    public static void Save(string path, byte[] bytes, string? password = null) => Save(path, bytes, password, null, null, false);

    /// <summary>As above, for bytes encrypted for recipients: read back with the private key of <paramref name="certificate"/>.</summary>
    public static void Save(string path, byte[] bytes, X509Certificate2 certificate) => Save(path, bytes, null, certificate, null, false);

    /// <summary>
    /// As above; with the <paramref name="source"/> the bytes come from, a file that opens only by
    /// a rebuild the source did not need, or (with <paramref name="samePages"/>) that has another
    /// number of pages, is refused: opening alone is not proof that nothing was lost.
    /// </summary>
    internal static void Save(string path, byte[] bytes, string? password, PdfDocument? source, bool samePages) =>
        Save(path, bytes, password, null, source, samePages);

    internal static void Save(string path, byte[] bytes, string? password, X509Certificate2? certificate, PdfDocument? source, bool samePages)
    {
        string full = Path.GetFullPath(path);
        string temp = Path.Combine(Path.GetDirectoryName(full)!, $".{Guid.NewGuid():N}.pdf.tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.SetAttributes(temp, File.GetAttributes(temp) | FileAttributes.Hidden);
            byte[] back = File.ReadAllBytes(temp);
            if (!back.AsSpan().SequenceEqual(bytes)) throw new IOException("The file did not read back as written.");
            using (var reopened = certificate is null ? PdfDocument.Open(back, password) : PdfDocument.Open(back, certificate))
            {
                if (source is not null && reopened.XrefRebuilt && !source.XrefRebuilt)
                    throw PdfReadException.Damaged("The file does not read back without repairs.");
                if (source is not null && samePages && reopened.Pages.Count != source.Pages.Count)
                    throw PdfReadException.Damaged("The file reads back with another number of pages.");
            }
            Replace(temp, full);
        }
        catch
        {
            try
            {
                File.Delete(temp);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The original is what matters; the stray file is hidden and harmless.
            }
            throw;
        }
    }

    // The swap is done by now, so a failure here must not make the save look failed.
    private static void Restore(string path, FileAttributes attributes, DateTime created)
    {
        try
        {
            File.SetCreationTimeUtc(path, created);
            File.SetAttributes(path, attributes == 0 ? FileAttributes.Normal : attributes);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void Replace(string temp, string path)
    {
        if (!File.Exists(path))
        {
            File.SetAttributes(temp, FileAttributes.Normal);
            File.Move(temp, path);
            return;
        }
        var attributes = File.GetAttributes(path);
        var created = File.GetCreationTimeUtc(path);
        try
        {
            // Keeps the original's permissions, alternate streams and creation time where the file system has them.
            File.Replace(temp, path, null, ignoreMetadataErrors: true);
        }
        catch (IOException e) when ((e.HResult & 0xFFFF) is 1 or 50 or 87) // invalid function, not supported, invalid parameter
        {
            File.SetAttributes(temp, FileAttributes.Normal);
            File.Move(temp, path, overwrite: true);
        }
        Restore(path, attributes, created);
    }
}
