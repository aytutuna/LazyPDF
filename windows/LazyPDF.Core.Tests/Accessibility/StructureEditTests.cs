using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StructureEditTests
{
    private static string Kinds(StructElement element) =>
        string.Join(",", element.Kids.Select(k => k switch { StructElement e => e.Type, StructContent c => "mcid" + c.Mcid, _ => "obj" }));

    [Fact]
    public void StandardTypeIsWrittenAsIs()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");

        Assert.True(tree.SetType(p, "H2"));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["H1", "H2", "Figure"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal(2, read.RoleMap.Count);
    }

    [Fact]
    public void CustomTypeKeepsOrAddsARoleMapEntry()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");
        var h1 = tree.Elements.First(e => e.Type == "H1");

        Assert.True(tree.SetType(h1, "Heading"));
        Assert.Equal("H1", tree.RoleMap["Heading"]);
        Assert.True(tree.SetType(p, "Warning"));
        Assert.Equal("P", tree.RoleMap["Warning"]);
        Assert.True(tree.SetType(p, "Aside", "Div"));
        Assert.Equal("Div", tree.RoleMap["Aside"]);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["Heading", "Aside", "Figure"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal("P", read.RoleMap["Warning"]);
        Assert.Equal("Div", read.StandardType("Aside"));
    }

    [Fact]
    public void ATypeThatDoesNotResolveIsRefused()
    {
        using var document = TaggedFile.Open(o => o[8] = o[8].Replace("/Weird /Nope", "/Weird /Nope /A /B /B /A"));
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");

        Assert.False(tree.SetType(p, ""));
        Assert.False(tree.SetType(p, "Weird"));
        Assert.False(tree.SetType(p, "A"));
        Assert.False(tree.SetType(p, "New", "Weird"));
        Assert.False(tree.SetType(p, "New", "New"));
        Assert.Equal("P", p.Type);
        Assert.False(tree.RoleMap.ContainsKey("New"));
    }

    [Fact]
    public void AnElementWithoutATypeNeedsAnExplicitTarget()
    {
        using var document = TaggedFile.Open(o => o[11] = "<</Type /StructElem /P 9 0 R /K 1>>");
        var tree = StructureTree.Read(document)!;
        var untyped = tree.Roots[0].Children.ElementAt(1);

        Assert.Equal("", untyped.Type);
        Assert.False(tree.SetType(untyped, "Custom"));
        Assert.True(tree.SetType(untyped, "Custom", "P"));
    }

    [Fact]
    public void TextPropertiesSurviveASave()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");
        p.Title = "Intro";
        p.Alt = "Spoken";
        p.ActualText = "Written";
        p.Lang = "de";
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!.Elements.First(e => e.Type == "P");
        Assert.Equal(("Intro", "Spoken", "Written", "de"), (read.Title, read.Alt, read.ActualText, read.Lang));
    }

    [Fact]
    public void MovesUpAndDownAmongAllKids()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var figure = root.Children.Last();
        var h1 = root.Children.First();

        Assert.True(tree.MoveUp(figure));
        Assert.Equal("H1,Figure,P", Kinds(root));
        Assert.False(tree.MoveUp(h1));
        Assert.True(tree.MoveDown(h1));
        Assert.Equal("Figure,H1,P", Kinds(root));
        Assert.False(tree.MoveDown(root.Children.Last()));
        Assert.False(tree.MoveUp(new StructElement("P")));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["Figure", "H1", "P"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal("H1", read.ElementFor(0, 0)!.Type);
        Assert.Equal("Figure", read.ElementFor(0, 2)!.Type);
    }

    [Fact]
    public void RootsAndContentMoveToo()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var second = new StructElement("Document");
        tree.Add(null, second);
        var h1 = tree.Roots[0].Children.First();
        var content = h1.Kids.OfType<StructContent>().Single();
        tree.Add(h1, new StructContent(0, 7));

        Assert.True(tree.MoveUp(second));
        Assert.Same(second, tree.Roots[0]);
        Assert.False(tree.MoveUp(second));
        Assert.True(tree.MoveDown(content));
        Assert.Equal("mcid7,mcid0", Kinds(h1));
    }

    [Fact]
    public void IndentGoesIntoThePreviousSibling()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var h1 = root.Children.First();
        var p = root.Children.ElementAt(1);

        Assert.False(tree.Indent(h1));
        Assert.True(tree.Indent(p));
        Assert.Equal("H1,Figure", Kinds(root));
        Assert.Equal("mcid0,P", Kinds(h1));
        Assert.Same(h1, p.Parent);
        Assert.False(tree.Indent(new StructElement("P")));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal("P", read.ElementFor(0, 1)!.Type);
        Assert.Equal("H1", read.ElementFor(0, 1)!.Parent!.Type);
    }

    [Fact]
    public void IndentIsRefusedAfterContent()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var figure = root.Children.Last();
        tree.Add(root, new StructContent(0, 9), 2);

        Assert.False(tree.Indent(figure));
        Assert.Equal("H1,P,mcid9,Figure", Kinds(root));
    }

    [Fact]
    public void OutdentGoesAfterTheParent()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var p = root.Children.ElementAt(1);
        Assert.True(tree.Indent(p));
        Assert.True(tree.Indent(root.Children.Last()));
        Assert.Equal("H1", Kinds(root));

        var h1 = root.Children.Single();
        Assert.True(tree.Outdent(p));
        Assert.Equal("H1,P", Kinds(root));
        Assert.Equal("mcid0,Figure", Kinds(h1));
        Assert.False(tree.Outdent(root));
        Assert.False(tree.Outdent(new StructElement("P")));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!;
        Assert.Equal("H1", read.ElementFor(0, 2)!.Parent!.Type);
        Assert.Equal("Document", read.ElementFor(0, 1)!.Parent!.Type);
    }

    [Fact]
    public void OutdentFromARootChildMakesARoot()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Roots[0].Children.ElementAt(1);

        Assert.True(tree.Outdent(p));
        Assert.Equal(2, tree.Roots.Count);
        Assert.Same(p, tree.Roots[1]);
        Assert.Null(p.Parent);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.Equal(["Document", "P"], StructureTree.Read(again)!.Roots.Select(r => r.Type));
    }

    [Fact]
    public void UnwrapKeepsElementsInPlace()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var div = new StructElement("Div");
        tree.Add(root, div, 1);
        tree.Move(root.Children.First(c => c.Type == "P"), div, -1);
        tree.Move(root.Children.First(c => c.Type == "Figure"), div, -1);
        Assert.Equal("H1,Div", Kinds(root));
        tree.Write(document);
        int number = div.Reference!.Number;

        Assert.True(tree.Unwrap(div));
        Assert.Equal("H1,P,Figure", Kinds(root));
        Assert.Null(div.Parent);
        tree.Write(document);

        Assert.Null(document.Get(number));
        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["H1", "P", "Figure"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal("Document", read.ElementFor(0, 1)!.Parent!.Type);
    }

    [Fact]
    public void UnwrapMovesContentIntoTheParentAtItsPlace()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var p = root.Children.ElementAt(1);
        int number = p.Reference!.Number;
        tree.Add(p, new StructObject(0, document.Pages[0].Reference));

        Assert.True(tree.Unwrap(p));
        Assert.Equal("H1,mcid1,obj,Figure", Kinds(root));
        tree.Write(document);

        Assert.Null(document.Get(number));
        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal("Document", read.ElementFor(0, 1)!.Type);
        Assert.Equal("Figure", read.ElementFor(0, 2)!.Type);
        Assert.Equal("H1", read.ElementFor(0, 0)!.Type);
        Assert.Equal("H1,mcid1,obj,Figure", Kinds(read.Roots[0]));
    }

    [Fact]
    public void UnwrapOfARootPromotesItsElements()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        Assert.True(tree.Unwrap(tree.Roots[0]));
        Assert.Equal(["H1", "P", "Figure"], tree.Roots.Select(r => r.Type));
        Assert.All(tree.Roots, r => Assert.Null(r.Parent));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["H1", "P", "Figure"], read.Roots.Select(r => r.Type));
        Assert.Equal("P", read.ElementFor(0, 1)!.Type);
    }

    [Fact]
    public void UnwrapRefusesWhatARootCannotHold()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        tree.Add(root, new StructContent(0, 5));

        Assert.False(tree.Unwrap(root));
        Assert.Single(tree.Roots);
        Assert.False(tree.Unwrap(new StructElement("P")));
    }

    [Fact]
    public void ElementsWithoutKidsEditCleanly()
    {
        using var document = TaggedFile.Open(o => o[11] = "<</Type /StructElem /S /P /P 9 0 R>>");
        var tree = StructureTree.Read(document)!;
        var p = tree.Roots[0].Children.ElementAt(1);

        Assert.Empty(p.Kids);
        Assert.True(tree.Indent(p));
        Assert.True(tree.Outdent(p));
        Assert.True(tree.MoveUp(p));
        Assert.True(tree.Unwrap(p));
        Assert.Equal("H1,Figure", Kinds(tree.Roots[0]));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.Equal(["H1", "Figure"], StructureTree.Read(again)!.Roots[0].Children.Select(c => c.Type));
    }

    [Fact]
    public void ARoleMapLoopDoesNotStopEditing()
    {
        using var document = TaggedFile.Open(o => o[8] = o[8].Replace("/Weird /Nope", "/A /B /B /A"));
        var tree = StructureTree.Read(document)!;
        var p = tree.Roots[0].Children.ElementAt(1);

        Assert.True(tree.SetType(p, "H2"));
        Assert.True(tree.Indent(p));
        tree.Write(document);
        Assert.Equal("B", StructureTree.Read(document)!.RoleMap["A"]);
    }

    [Fact]
    public void AnIdTheTreeLacksIsAddedToTheIdTree()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        tree.Roots[0].Children.First().Id = "intro";
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var entry = Assert.Single(PdfNameTree.Read(again, read.Dictionary["IDTree"]));
        Assert.Equal("intro", PdfNameTree.TextOf(entry.Key));
        Assert.Equal(read.Roots[0].Children.First().Reference!.Number, ((PdfReference)entry.Value).Number);

        read.Roots[0].Children.First().Id = null;
        read.Write(again);
        Assert.Empty(PdfNameTree.Read(again, read.Dictionary["IDTree"]));
    }

    [Fact]
    public void TheIdTreeKeepsTheBytesOfAnId()
    {
        byte[] raw = [0xFE, 0xFF, 0x00, 0x74, 0x00, 0x68, 0x00, 0x31];
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var first = tree.Roots[0].Children.First();
        first.Id = "th1";
        first.Dictionary["ID"] = new PdfString(raw, true);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        read.Roots[0].Children.ElementAt(1).Title = "second";
        read.Write(again);

        var entry = Assert.Single(PdfNameTree.Read(again, read.Dictionary["IDTree"]));
        Assert.Equal(raw, System.Text.Encoding.Latin1.GetBytes(entry.Key));
        Assert.Equal(raw, ((PdfString)again.Resolve(read.Roots[0].Children.First().Dictionary["ID"])!).Bytes);
    }

    [Fact]
    public void AnIdTreeThatIsNotADictionaryIsReplaced()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        tree.Dictionary["IDTree"] = new PdfNumber(7);
        tree.Roots[0].Children.First().Id = "intro";
        tree.Write(document);

        Assert.IsType<PdfDictionary>(document.Resolve(tree.Dictionary["IDTree"]));
        Assert.Equal("intro", PdfNameTree.TextOf(Assert.Single(PdfNameTree.Read(document, tree.Dictionary["IDTree"])).Key));
    }
}
