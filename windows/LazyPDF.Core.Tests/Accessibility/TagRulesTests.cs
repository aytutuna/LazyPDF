using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TagRulesTests
{
    [Theory]
    [InlineData("", "Document", null)]
    [InlineData("Div", "Document", TagRules.RootOnly)]
    [InlineData("Document", "Part", null)]
    [InlineData("Part", "Art", null)]
    [InlineData("Sect", "Part", TagRules.TopLevel)]
    [InlineData("Document", "Sect", null)]
    [InlineData("Sect", "H1", null)]
    [InlineData("Div", "H", null)]
    [InlineData("Div", "P", null)]
    [InlineData("P", "Span", null)]
    [InlineData("P", "Link", null)]
    [InlineData("P", "Figure", null)]
    [InlineData("P", "P", TagRules.TextKids)]
    [InlineData("H2", "P", TagRules.TextKids)]
    [InlineData("H2", "Span", null)]
    [InlineData("Span", "Table", TagRules.TextKids)]
    [InlineData("Link", "Span", null)]
    [InlineData("Link", "L", TagRules.TextKids)]
    [InlineData("Figure", "Caption", null)]
    [InlineData("Figure", "P", null)]
    [InlineData("Figure", "TD", TagRules.NeedsRow)]
    [InlineData("Div", "Caption", TagRules.NeedsCaptionParent)]
    [InlineData("Table", "Caption", null)]
    [InlineData("L", "Caption", null)]
    [InlineData("Table", "TR", null)]
    [InlineData("Table", "THead", null)]
    [InlineData("Table", "P", TagRules.TableKids)]
    [InlineData("Table", "TD", TagRules.NeedsRow)]
    [InlineData("THead", "TR", null)]
    [InlineData("TBody", "TH", TagRules.NeedsRow)]
    [InlineData("TFoot", "TR", null)]
    [InlineData("Div", "TR", TagRules.NeedsTableOrPart)]
    [InlineData("", "TR", TagRules.NeedsTableOrPart)]
    [InlineData("Div", "THead", TagRules.NeedsTable)]
    [InlineData("TR", "TH", null)]
    [InlineData("TR", "TD", null)]
    [InlineData("TR", "P", TagRules.RowKids)]
    [InlineData("TD", "P", null)]
    [InlineData("TD", "L", null)]
    [InlineData("TD", "Table", null)]
    [InlineData("TH", "Span", null)]
    [InlineData("TD", "TD", TagRules.NeedsRow)]
    [InlineData("L", "LI", null)]
    [InlineData("L", "P", TagRules.ListKids)]
    [InlineData("Div", "LI", TagRules.NeedsList)]
    [InlineData("LI", "Lbl", null)]
    [InlineData("LI", "LBody", null)]
    [InlineData("LI", "P", TagRules.ItemKids)]
    [InlineData("L", "Lbl", TagRules.NeedsItem)]
    [InlineData("Lbl", "Span", null)]
    [InlineData("Lbl", "P", TagRules.TextKids)]
    [InlineData("LBody", "P", null)]
    [InlineData("LBody", "L", null)]
    [InlineData("TOC", "TOCI", null)]
    [InlineData("TOC", "TOC", null)]
    [InlineData("TOC", "P", TagRules.TocKids)]
    [InlineData("Div", "TOCI", TagRules.NeedsToc)]
    [InlineData("TOCI", "Lbl", null)]
    [InlineData("TOCI", "LBody", TagRules.NeedsItem)]
    [InlineData("TOC", "Caption", null)]
    [InlineData("P", "NonStruct", null)]
    [InlineData("H2", "Private", null)]
    [InlineData("TOCI", "Link", null)]
    [InlineData("Ruby", "RB", null)]
    [InlineData("Ruby", "Span", TagRules.RubyKids)]
    [InlineData("Div", "RT", TagRules.NeedsRuby)]
    [InlineData("Warichu", "WT", null)]
    [InlineData("Warichu", "RT", TagRules.NeedsRuby)]
    [InlineData("Warichu", "Span", TagRules.WarichuKids)]
    [InlineData("Div", "WP", TagRules.NeedsWarichu)]
    public void PlacesTypes(string parent, string child, string? reason)
    {
        // A pair is wrong from one side or the other; the first rule that fails names it.
        Assert.Equal(reason ?? "", TagRules.CanPlace(parent, child) ?? "");
    }

    [Fact]
    public void HeadingsOfAnyLevelAreTextParents()
    {
        Assert.Null(TagRules.CanPlace("H3", "Span"));
        Assert.Equal(TagRules.TextKids, TagRules.CanPlace("H6", "Div"));
        Assert.Null(TagRules.CanPlace("Sect", "H4"));
    }

    [Fact]
    public void TypesResolveThroughTheRoleMap()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        tree.RoleMap["Row"] = "TR";
        tree.RoleMap["Loop"] = "Loop2";
        tree.RoleMap["Loop2"] = "Loop";
        var table = new StructElement("Table");
        var row = new StructElement("Row");
        var root = tree.Roots[0];

        Assert.Null(TagRules.CanPlace(tree, table, row));
        Assert.Equal(TagRules.NeedsTableOrPart, TagRules.CanPlace(tree, root, row));
        Assert.Null(TagRules.CanPlace(tree, root, new StructElement("Loop")));
        Assert.Equal(TagRules.RootOnly, TagRules.CanPlace(tree, root, new StructElement("Document")));
        Assert.Null(TagRules.CanPlace(tree, null, new StructElement("Document")));
    }

    [Fact]
    public void SettingATypeChecksParentKidsContentAndLinks()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var h1 = root.Children.First();
        var p = root.Children.ElementAt(1);

        Assert.Null(TagRules.CanSetType(tree, p, "H2"));
        Assert.Equal(TagRules.NeedsRow, TagRules.CanSetType(tree, p, "TD"));
        Assert.Equal(TagRules.NoContent, TagRules.CanSetType(tree, h1, "L"));
        Assert.Equal(TagRules.LinkObject, TagRules.CanSetType(tree, p, "Link"));
        Assert.Equal(TagRules.TableKids, TagRules.CanSetType(tree, root, "Table"));
        Assert.Null(TagRules.CanSetType(tree, root, "Sect"));
        Assert.Equal(TagRules.Unmapped, TagRules.CanSetType(tree, p, "Warning", "Weird"));
        Assert.Null(TagRules.CanSetType(tree, p, "Warning", "P"));

        tree.Add(p, new StructObject(0, new PdfReference(99, 0)));
        Assert.Null(TagRules.CanSetType(tree, p, "Link"));
    }

    [Fact]
    public void ReasonsAreMessages()
    {
        foreach (string key in new[]
        {
            TagRules.RootOnly, TagRules.TopLevel, TagRules.NeedsTable, TagRules.NeedsTableOrPart, TagRules.NeedsRow, TagRules.NeedsList,
            TagRules.NeedsItem, TagRules.NeedsCaptionParent, TagRules.NeedsToc, TagRules.NeedsRuby, TagRules.NeedsWarichu, TagRules.TableKids,
            TagRules.PartKids, TagRules.RowKids, TagRules.ListKids, TagRules.ItemKids, TagRules.TocKids, TagRules.RubyKids,
            TagRules.WarichuKids, TagRules.TextKids, TagRules.NoContent, TagRules.LinkObject, TagRules.Unmapped,
        })
        {
            Assert.NotEqual(key, AccessibilityText.PlacementReason(key));
        }
    }
}
