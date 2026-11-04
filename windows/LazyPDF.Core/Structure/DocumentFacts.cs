namespace LazyPDF.Core;

public enum FormKind { None, AcroForm, Xfa }

/// <summary>
/// What the Properties panel shows about an open file. <see cref="Permissions"/> is null for a file
/// that is not encrypted. The page size is the first page's, as shown (rotation and user unit
/// applied), in points.
/// </summary>
public sealed record DocumentFacts(
    string Version, long FileSize, int PageCount, double FirstPageWidth, double FirstPageHeight, DocumentMetadata Metadata, string? Language,
    bool IsTagged, bool IsLinearized, bool IsEncrypted, PdfPermissions? Permissions, bool IsSigned, bool IsCertified, FormKind Form,
    bool HasJavaScript, bool HasBookmarks, bool IsPortfolio, int AttachmentCount, int LayerCount, int? PdfAPart, string? PdfAConformance,
    int RepairCount)
{
    public static DocumentFacts Read(PdfDocument document)
    {
        var first = document.Pages.Count > 0 ? new PageGeometry(document.Pages[0]) : null;
        var form = document.Dict(document.Catalog, "AcroForm");
        FormKind kind = document.HasXfa ? FormKind.Xfa
            : document.Array(form, "Fields") is { Items.Count: > 0 } ? FormKind.AcroForm : FormKind.None;
        return new DocumentFacts(
            document.Version, document.Length, document.Pages.Count, first?.Width ?? 0, first?.Height ?? 0,
            DocumentMetadata.Read(document), PdfText.Read(document, document.Catalog, "Lang"),
            document.IsTagged, document.IsLinearized, document.IsEncrypted, document.Security?.Permissions, document.IsSigned, document.IsCertified, kind,
            PdfActions.HasJavaScript(document), document.Dict(document.Catalog, "Outlines")?["First"] is not null, document.Dict(document.Catalog, "Collection") is not null,
            PdfAttachments.List(document).Count, PdfLayers.Read(document).Layers.Count, document.PdfAPart, document.PdfAConformance,
            document.Repairs.Count);
    }
}
