using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Documents;

/// <summary>A file read and ready for the engine: PDF bytes, and where they came from.</summary>
/// <param name="Path">The file to save back to; null for pictures and text, which become a new document.</param>
/// <param name="Made">The bytes were made from a picture or a text file, so they differ from anything on disk.</param>
/// <param name="Note">Something the person should hear about how the file was read.</param>
/// <param name="ReadOnly">The file has the read-only attribute, so saving over it fails.</param>
/// <param name="Hash">SHA256 of the bytes read from a PDF on disk, so a file that was only touched is told from one that changed; null for anything else and for files too large to hash.</param>
/// <param name="Stamp">What the file looked like just before it was read, so a later change by someone else shows.</param>
public sealed record OpenSource(byte[] Bytes, string? Path, string Title, bool Made, string? Note = null, DiskStamp? Stamp = null, bool ReadOnly = false, string? FileId = null, byte[]? Hash = null);

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
    /// <summary>What Core says of a file it cannot hold in one array; <see cref="Problems.Open"/> tells it from other unsupported files by this.</summary>
    internal const string TooLarge = "The file is too large.";

    internal const string IsFolder = "The path is a folder.";

    public OpenSource Read(string path)
    {
        if (Directory.Exists(path)) throw new InvalidDataException(IsFolder);
        if (new FileInfo(path).Length > int.MaxValue) throw new PdfReadException(PdfReadProblem.Unsupported, TooLarge);
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
        return new OpenSource(bytes, path, System.IO.Path.GetFileName(path), false, Stamp: stamp, ReadOnly: new FileInfo(path).IsReadOnly, FileId: Identity(path),
                          Hash: bytes.Length <= DocumentTab.HashLimit ? System.Security.Cryptography.SHA256.HashData(bytes) : null);
    }

    private static string? Identity(string path)
    {
        try
        {
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return GetFileInformationByHandle(handle, out var info)
                ? $"{info.VolumeSerialNumber}:{info.FileIndexHigh}:{info.FileIndexLow}"
                : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file, out ByHandleFileInformation info);

    static DocumentOpener() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    internal static string Decode(byte[] bytes)
    {
        if (bytes is [0xFF, 0xFE, ..]) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes is [0xFE, 0xFF, ..]) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿');
        }
        catch (DecoderFallbackException)
        {
            try
            {
                return Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage).GetString(bytes);
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException)
            {
                return Encoding.Latin1.GetString(bytes);
            }
        }
    }
}
