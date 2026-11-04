using LazyPDF.App.Tools;
using Xunit;

namespace LazyPDF.App.Tests;

// The catalog a later engineer adds a tool to: every tool in a group, each with a title and a glyph.
public sealed class ToolCatalogTests
{
    private static readonly string[] Expected =
    [
        "comment", "editcontent", "pages", "combine", "stamps", "forms", "fillsign", "certificates", "protect", "redact",
        "optimize", "sanitize", "compare", "export", "create", "ocr", "accessibility", "standards", "measure", "batch", "metadata",
    ];

    [Fact]
    public void EveryToolOfTheShellIsListed() =>
        Assert.Equal(Expected.Order(), ToolCatalog.Tools.Select(t => t.Id).Order());

    [Fact]
    public void IdsAreUniqueAndLowerCase()
    {
        Assert.Equal(ToolCatalog.Tools.Count, ToolCatalog.Tools.Select(t => t.Id).Distinct().Count());
        Assert.All(ToolCatalog.Tools, t => Assert.Equal(t.Id.ToLowerInvariant(), t.Id));
    }

    [Fact]
    public void EveryToolHasWordsAndAGlyph() =>
        Assert.All(ToolCatalog.Tools, t =>
        {
            Assert.NotEmpty(t.Title);
            Assert.NotEmpty(t.Summary);
            Assert.Single(t.Glyph);
            Assert.InRange(t.Glyph[0], '', '');
        });

    [Fact]
    public void EveryGroupOfTheStripHasATool() =>
        Assert.All(Enum.GetValues<ToolGroup>(), group =>
        {
            Assert.Contains(ToolCatalog.Tools, t => t.Group == group);
            Assert.NotEmpty(ToolCatalog.GroupTitle(group));
            Assert.Single(ToolCatalog.GroupGlyph(group));
        });

    [Fact]
    public void TheGroupsAreTheOnesOfTheStrip() =>
        Assert.Equal(
            ["Comment", "Edit", "Pages", "Forms", "Sign", "Protect", "Convert", "Scan and OCR", "Compare", "Accessibility"],
            Enum.GetValues<ToolGroup>().Select(ToolCatalog.GroupTitle));

    [Fact]
    public void TheRailHasTheSevenSidePanels() =>
        Assert.Equal(["pages", "bookmarks", "attachments", "layers", "comments", "signatures", "search"], ToolCatalog.SidePanels.Select(p => p.Id));

    [Fact]
    public void ToolsAndSidePanelsAreFoundById()
    {
        Assert.Equal("Combine files", ToolCatalog.Find("combine")?.Title);
        Assert.Equal("Bookmarks", ToolCatalog.FindSide("bookmarks")?.Title);
        Assert.Null(ToolCatalog.Find("nothing"));
        Assert.Null(ToolCatalog.FindSide("nothing"));
    }
}
