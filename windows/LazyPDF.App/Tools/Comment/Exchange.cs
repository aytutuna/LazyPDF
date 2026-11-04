using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Comment;

/// <summary>What an export wrote: the file, how many comments are in it and how many things XFDF has no room for.</summary>
public sealed record Exported(byte[] Data, int Count, int Left);

/// <summary>Comments in and out of the file as FDF or XFDF, and burned into the pages.</summary>
public static class Exchange
{
    public static bool IsXfdf(string path) => string.Equals(Path.GetExtension(path), ".xfdf", StringComparison.OrdinalIgnoreCase);

    public static PdfDocument Open(byte[] bytes, string? password, X509Certificate2? certificate) =>
        certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate);

    public static Exported Export(PdfDocument document, string? pdfName, bool xfdf)
    {
        var fdf = PdfFdf.Export(document, pdfName);
        int left = xfdf ? fdf.Annotations.Count(a => IsPicture(a.Dictionary)) : 0;
        return new Exported(xfdf ? PdfXfdf.Write(fdf) : PdfFdf.Write(fdf), fdf.Annotations.Count(a => a.Dictionary["Subtype"] is not PdfName { Value: "Popup" }), left);
    }

    // XFDF keeps no attachment data and no image of a picture stamp.
    private static bool IsPicture(PdfDictionary d) =>
        d["Subtype"] is PdfName { Value: "FileAttachment" } || (d["Subtype"] is PdfName { Value: "Stamp" } && d["Name"] is PdfName { Value: "Image" });

    public static FdfImportResult Import(PdfDocument document, byte[] data, bool xfdf, IFontSource fonts)
    {
        var fdf = xfdf ? PdfXfdf.Read(data) : PdfFdf.Read(data);
        return PdfFdf.Import(document, fdf, fonts);
    }

    /// <summary>The marks that flattening would burn in.</summary>
    public static int Flattenable(PdfDocument document) =>
        PdfAnnotations.ReadAll(document).Count(a => PdfAnnotationFlattener.DefaultTypes.Contains(a.Type) && a.HasAppearance && !a.Flags.HasFlag(AnnotationFlags.Hidden) && !a.Flags.HasFlag(AnnotationFlags.NoView));

    public static int Flatten(PdfDocument document, CancellationToken token)
    {
        int burned = 0;
        foreach (var page in document.Pages)
        {
            token.ThrowIfCancellationRequested();
            burned += PdfAnnotationFlattener.Flatten(document, page);
        }
        return burned;
    }

    /// <summary>Whether marks may be added: the permissions allow annotating, and a certification, if there is one, allows it too.</summary>
    public static bool CanComment(PdfDocument document) =>
        PdfAnnotations.CanAnnotate(document) && (!document.IsCertified || CertifiedLevel(document) >= 3);

    // The /DocMDP permission of the certification (12.8.2.2); 2 when the file does not say.
    private static long CertifiedLevel(PdfDocument document)
    {
        long level = 2;
        var signature = document.Resolve(document.Dict(document.Catalog, "Perms")?["DocMDP"]) as PdfDictionary;
        if (document.Array(signature, "Reference") is not { } references) return level;
        foreach (var item in references.Items)
        {
            if (document.Resolve(item) is PdfDictionary reference && document.Name(reference, "TransformMethod") == "DocMDP"
                && document.Dict(reference, "TransformParams") is { } parameters && document.Integer(parameters, "P") is { } p)
            {
                level = p;
            }
        }
        return level;
    }
}
