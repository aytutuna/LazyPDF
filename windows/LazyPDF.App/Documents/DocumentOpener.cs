using System.Text;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Documents;

/// <summary>A file read and ready for the engine: PDF bytes, and where they came from.</summary>
/// <param name="Path">The file to save back to; null for pictures and text, which become a new document.</param>
/// <param name="Made">The bytes were made from a picture or a text file, so they differ from anything on disk.</param>
/// <param name="Note">Something the person should hear about how the file was read.</param>
/// <param name="Stamp">What the file looked like just before it was read, so a later change by someone else shows.</param>
public sealed record OpenSource(byte[] Bytes, string? Path, string Title, bool Made, string? Note = null, DiskStamp? Stamp = null);

/// <summary>When a file was last written and how long it was, the two things that tell a program it changed.</summary>
public sealed record DiskStamp(DateTime Write, long Length)
{
    /// <summary>Null when the path is null or the file is not there.</summary>
    public static DiskStamp? Of(string? path)
    {
        if (path is null) return null;
        var info = new FileInfo(path);
        return info.Exists ? new DiskStamp(info.LastWriteTimeUtc, info.Length) : null;
    }
}

/// <summary>Reads what the open dialog and the drop target hand over: PDFs as they are, pictures and text turned into a PDF.</summary>
public sealed class DocumentOpener(IImageCodec codec, IFontSource fonts)
{
    public OpenSource Read(string path)
    {
        var stamp = DiskStamp.Of(path);
        byte[] bytes = File.ReadAllBytes(path);
        string stem = System.IO.Path.GetFileNameWithoutExtension(path);
        if (FileKinds.IsPicture(path))
        {
            try
            {
                var made = PdfFromPictures.Create([bytes], codec);
                return new OpenSource(made.Bytes, null, stem + ".pdf", true);
            }
            catch (ArgumentException)
            {
                throw new InvalidDataException(ExportText.NoUsablePicture);
            }
        }
        if (FileKinds.IsText(path))
        {
            var made = PdfFromText.Create(Decode(bytes), fonts);
            return new OpenSource(made.Bytes, null, stem + ".pdf", true, made.Missing.Count > 0 ? Loc.T("Some characters have no letter in the font and were left out.") : null);
        }
        return new OpenSource(bytes, path, System.IO.Path.GetFileName(path), false, Stamp: stamp);
    }

    internal static string Decode(byte[] bytes)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿');
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(bytes);
        }
    }
}
