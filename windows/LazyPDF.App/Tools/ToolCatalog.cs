using LazyPDF.App.Panels.Attachments;
using LazyPDF.App.Panels.Bookmarks;
using LazyPDF.App.Panels.Comments;
using LazyPDF.App.Panels.Layers;
using LazyPDF.App.Panels.Pages;
using LazyPDF.App.Panels.Search;
using LazyPDF.App.Panels.Signatures;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.App.Tools.Batch;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Tools.Combine;
using LazyPDF.App.Tools.Compare;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.Create;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.App.Tools.Export;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.App.Tools.Forms;
using LazyPDF.App.Tools.Measure;
using LazyPDF.App.Tools.Metadata;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.App.Tools.Optimize;
using LazyPDF.App.Tools.Pages;
using LazyPDF.App.Tools.PdfUa;
using LazyPDF.App.Tools.Protect;
using LazyPDF.App.Tools.Redact;
using LazyPDF.App.Tools.Sanitize;
using LazyPDF.App.Tools.Standards;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools;

/// <summary>The groups of the tool strip, in the order it shows them.</summary>
public enum ToolGroup
{
    Review,
    Edit,
    Organize,
    FormsAndSignatures,
    Security,
    CreateAndExport,
    Optimize,
    Check,
}

/// <param name="Id">Stable and lower-case; the home tiles and the saved settings refer to it.</param>
/// <param name="Glyph">A Segoe Fluent Icons glyph.</param>
/// <param name="Summary">One sentence for the tooltip and the panel's first line.</param>
/// <param name="Create">Makes the panel; the shell makes it once, the first time the tool is picked.</param>
public sealed record ToolInfo(string Id, ToolGroup Group, string Title, string Glyph, string Summary, Func<ToolPanel> Create);

/// <summary>A panel on the left rail beside the stage.</summary>
public sealed record SidePanelInfo(string Id, string Title, string Glyph, string Summary, Func<ToolPanel> Create);

/// <summary>
/// Every tool, in the groups of the tool strip, and the side panels of the rail. A tool is built in its own
/// folder under Tools/ and is listed here once, with the panel it opens.
/// </summary>
public static class ToolCatalog
{
    public static IReadOnlyList<ToolInfo> Tools { get; } =
    [
        new("comment", ToolGroup.Review, Loc.T("Comment"), "\uE90A", Loc.T("Highlight, draw and leave notes on the pages."), () => new CommentPanel()),
        new("measure", ToolGroup.Review, Loc.T("Measure"), "\uECC6", Loc.T("Measure distances, perimeters and areas on a page."), () => new MeasurePanel()),
        new("compare", ToolGroup.Review, Loc.T("Compare files"), "\uE8F1", Loc.T("Show what changed between two files."), () => new ComparePanel()),
        new("editcontent", ToolGroup.Edit, Loc.T("Edit text and pictures"), "\uE70F", Loc.T("Change the words and pictures already on a page."), () => new EditContentPanel()),
        new("stamps", ToolGroup.Edit, Loc.T("Stamps and watermarks"), "", Loc.T("Add a stamp, a watermark, page numbers or a header."), () => new StampsPanel()),
        new("pages", ToolGroup.Organize, Loc.T("Organize pages"), "\uE8A1", Loc.T("Rotate, move, delete, crop and extract pages."), () => new PagesPanel()),
        new("combine", ToolGroup.Organize, Loc.T("Combine files"), "\uE8F4", Loc.T("Join files into a new one, or split this one."), () => new CombinePanel()),
        new("batch", ToolGroup.Organize, Loc.T("Batch"), "\uE8FD", Loc.T("Do the same to every file in a folder."), () => new BatchPanel()),
        new("forms", ToolGroup.FormsAndSignatures, Loc.T("Form fields"), "\uE8D2", Loc.T("Fill in, add, change and flatten form fields."), () => new FormsPanel()),
        new("fillsign", ToolGroup.FormsAndSignatures, Loc.T("Fill and sign"), "\uE76D", Loc.T("Sign, initial, or add text and a date."), () => new FillSignPanel()),
        new("certificates", ToolGroup.FormsAndSignatures, Loc.T("Certificates"), "\uEB95", Loc.T("Sign with a certificate and check the signatures of a file."), () => new CertificatesPanel()),
        new("protect", ToolGroup.Security, Loc.T("Protect"), "\uE72E", Loc.T("Set a password and decide what others may do."), () => new ProtectPanel()),
        new("redact", ToolGroup.Security, Loc.T("Redact"), "\uE7B3", Loc.T("Remove text and pictures from the file for good."), () => new RedactPanel()),
        new("sanitize", ToolGroup.Security, Loc.T("Clean for sharing"), "", Loc.T("Take out hidden data before the file goes to someone else."), () => new SanitizePanel()),
        new("create", ToolGroup.CreateAndExport, Loc.T("Create"), "\uE8B9", Loc.T("Make a PDF from blank pages, pictures, text or the clipboard."), () => new CreatePanel()),
        new("export", ToolGroup.CreateAndExport, Loc.T("Export"), "\uE8AD", Loc.T("Save as Word, Excel, PowerPoint, HTML, text or pictures."), () => new ExportPanel()),
        new("optimize", ToolGroup.Optimize, Loc.T("Make smaller"), "\uE9D9", Loc.T("Shrink the file and see where its space goes."), () => new OptimizePanel()),
        new("ocr", ToolGroup.Optimize, Loc.T("Make searchable"), "", Loc.T("Recognize the text of scanned pages."), () => new OcrPanel()),
        new("metadata", ToolGroup.Check, Loc.T("Properties"), "\uE946", Loc.T("Title, author and the other facts stored in the file."), () => new MetadataPanel()),
        new("accessibility", ToolGroup.Check, Loc.T("Accessibility"), "\uE776", Loc.T("Check the file for screen readers and fix what is missing."), () => new AccessibilityPanel()),
        new("standards", ToolGroup.Check, Loc.T("PDF/A"), "\uE7C4", Loc.T("Check the file against PDF/A and convert it."), () => new StandardsPanel()),
        new("pdfua", ToolGroup.Check, Loc.T("PDF/UA"), "", Loc.T("Check the file against PDF/UA and mark it."), () => new PdfUaPanel()),
    ];

    public static IReadOnlyList<SidePanelInfo> SidePanels { get; } =
    [
        new("pages", Loc.T("Pages"), "\uE7C3", Loc.T("Thumbnails of every page."), () => new PagesSidePanel()),
        new("bookmarks", Loc.T("Bookmarks"), "\uE8A4", Loc.T("The bookmarks of the file."), () => new BookmarksSidePanel()),
        new("attachments", Loc.T("Attachments"), "\uE723", Loc.T("Files carried inside this one."), () => new AttachmentsSidePanel()),
        new("layers", Loc.T("Layers"), "\uE81E", Loc.T("Parts of the pages that can be shown or hidden."), () => new LayersSidePanel()),
        new("comments", Loc.T("Comments"), "\uE90A", Loc.T("Every note and mark, with replies."), () => new CommentsSidePanel()),
        new("signatures", Loc.T("Signatures"), "\uE929", Loc.T("Who signed the file and whether it changed since."), () => new SignaturesSidePanel()),
        new("search", Loc.T("Search"), "\uE721", Loc.T("Search for words in the file."), () => new SearchSidePanel()),
    ];

    public static ToolInfo? Find(string id) => Tools.FirstOrDefault(t => t.Id == id);

    public static SidePanelInfo? FindSide(string id) => SidePanels.FirstOrDefault(p => p.Id == id);

    public static string GroupTitle(ToolGroup group) => group switch
    {
        ToolGroup.Review => Loc.T("Review"),
        ToolGroup.Edit => Loc.T("Edit"),
        ToolGroup.Organize => Loc.T("Organize"),
        ToolGroup.FormsAndSignatures => Loc.T("Forms and signatures"),
        ToolGroup.Security => Loc.T("Security"),
        ToolGroup.CreateAndExport => Loc.T("Create and export"),
        ToolGroup.Optimize => Loc.T("Optimize"),
        _ => Loc.T("Check"),
    };

    public static string GroupGlyph(ToolGroup group) => group switch
    {
        ToolGroup.Review => "",
        ToolGroup.Edit => "",
        ToolGroup.Organize => "",
        ToolGroup.FormsAndSignatures => "",
        ToolGroup.Security => "",
        ToolGroup.CreateAndExport => "",
        ToolGroup.Optimize => "",
        _ => "",
    };
}
