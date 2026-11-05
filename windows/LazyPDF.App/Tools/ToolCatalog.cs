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
    Comment,
    Edit,
    Pages,
    Forms,
    Sign,
    Protect,
    Convert,
    ScanAndOcr,
    Compare,
    Accessibility,
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
        new("comment", ToolGroup.Comment, Loc.T("Comment"), "\uE90A", Loc.T("Highlight, draw and leave notes on the pages."), () => new CommentPanel()),
        new("measure", ToolGroup.Comment, Loc.T("Measure"), "\uECC6", Loc.T("Measure distances, perimeters and areas on a page."), () => new MeasurePanel()),
        new("editcontent", ToolGroup.Edit, Loc.T("Edit text and pictures"), "\uE70F", Loc.T("Change the words and pictures already on a page."), () => new EditContentPanel()),
        new("stamps", ToolGroup.Edit, Loc.T("Stamps and watermarks"), "\uE7C3", Loc.T("Add a stamp, a watermark, page numbers or a header."), () => new StampsPanel()),
        new("metadata", ToolGroup.Edit, Loc.T("Properties"), "\uE946", Loc.T("Title, author and the other facts stored in the file."), () => new MetadataPanel()),
        new("pages", ToolGroup.Pages, Loc.T("Organize pages"), "\uE8A1", Loc.T("Rotate, move, delete, crop and extract pages."), () => new PagesPanel()),
        new("combine", ToolGroup.Pages, Loc.T("Combine files"), "\uE8F4", Loc.T("Join files into a new one, or split this one."), () => new CombinePanel()),
        new("forms", ToolGroup.Forms, Loc.T("Form fields"), "\uE8D2", Loc.T("Fill in, add, change and flatten form fields."), () => new FormsPanel()),
        new("fillsign", ToolGroup.Sign, Loc.T("Fill and sign"), "\uE76D", Loc.T("Sign, initial, or add text and a date."), () => new FillSignPanel()),
        new("certificates", ToolGroup.Sign, Loc.T("Certificates"), "\uEB95", Loc.T("Sign with a certificate and check the signatures of a file."), () => new CertificatesPanel()),
        new("protect", ToolGroup.Protect, Loc.T("Protect"), "\uE72E", Loc.T("Set a password and decide what others may do."), () => new ProtectPanel()),
        new("redact", ToolGroup.Protect, Loc.T("Redact"), "\uE7B3", Loc.T("Remove text and pictures from the file for good."), () => new RedactPanel()),
        new("sanitize", ToolGroup.Protect, Loc.T("Clean for sharing"), "\uE74D", Loc.T("Take out hidden data before the file goes to someone else."), () => new SanitizePanel()),
        new("optimize", ToolGroup.Convert, Loc.T("Make smaller"), "\uE9D9", Loc.T("Shrink the file and see where its space goes."), () => new OptimizePanel()),
        new("export", ToolGroup.Convert, Loc.T("Export"), "\uE8AD", Loc.T("Save as Word, Excel, PowerPoint, HTML, text or pictures."), () => new ExportPanel()),
        new("create", ToolGroup.Convert, Loc.T("Create"), "\uE8B9", Loc.T("Make a PDF from blank pages, pictures, text or the clipboard."), () => new CreatePanel()),
        new("batch", ToolGroup.Convert, Loc.T("Batch"), "\uE8FD", Loc.T("Do the same to every file in a folder."), () => new BatchPanel()),
        new("ocr", ToolGroup.ScanAndOcr, Loc.T("Make searchable"), "\uE721", Loc.T("Recognize the text of scanned pages."), () => new OcrPanel()),
        new("compare", ToolGroup.Compare, Loc.T("Compare files"), "\uE8F1", Loc.T("Show what changed between two files."), () => new ComparePanel()),
        new("accessibility", ToolGroup.Accessibility, Loc.T("Accessibility"), "\uE776", Loc.T("Check the file for screen readers and fix what is missing."), () => new AccessibilityPanel()),
        new("standards", ToolGroup.Accessibility, Loc.T("PDF/A"), "\uE7C4", Loc.T("Check the file against PDF/A and convert it."), () => new StandardsPanel()),
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
        ToolGroup.Comment => Loc.T("Comment"),
        ToolGroup.Edit => Loc.T("Edit"),
        ToolGroup.Pages => Loc.T("Pages"),
        ToolGroup.Forms => Loc.T("Forms"),
        ToolGroup.Sign => Loc.T("Sign"),
        ToolGroup.Protect => Loc.T("Protect"),
        ToolGroup.Convert => Loc.T("Convert"),
        ToolGroup.ScanAndOcr => Loc.T("Scan and OCR"),
        ToolGroup.Compare => Loc.T("Compare"),
        _ => Loc.T("Accessibility"),
    };

    public static string GroupGlyph(ToolGroup group) => group switch
    {
        ToolGroup.Comment => "\uE90A",
        ToolGroup.Edit => "\uE70F",
        ToolGroup.Pages => "\uE8A1",
        ToolGroup.Forms => "\uE8D2",
        ToolGroup.Sign => "\uE76D",
        ToolGroup.Protect => "\uE72E",
        ToolGroup.Convert => "\uE8AD",
        ToolGroup.ScanAndOcr => "\uE721",
        ToolGroup.Compare => "\uE8F1",
        _ => "\uE776",
    };
}
