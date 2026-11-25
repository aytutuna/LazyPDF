using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StructureTreeTests
{
    [Fact]
    public void ReadsElementsAndMaps()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        var root = Assert.Single(tree.Roots);
        Assert.Equal("Document", root.Type);
        Assert.Equal(["H1", "P", "Figure"], root.Children.Select(c => c.Type));
        var h1 = root.Children.First();
        Assert.Equal("Head", h1.Title);
        Assert.Equal("tr", h1.Lang);
        Assert.Equal(0, h1.PageIndex);
        Assert.Equal(0, Assert.IsType<StructContent>(Assert.Single(h1.Kids)).Mcid);
        Assert.Equal("Body text", tree.Elements.First(e => e.Type == "P").ActualText);
        Assert.Equal("A picture", tree.Elements.First(e => e.Type == "Figure").Alt);
        Assert.Equal("H1", tree.RoleMap["Heading"]);
        Assert.True(tree.ClassMap.ContainsKey("Fancy"));
        Assert.Same(root, h1.Parent);
        Assert.False(tree.IsTruncated);
    }

    [Fact]
    public void ParentTreeFindsTheElementOfASequence()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        Assert.Equal("P", tree.ElementFor(0, 1)!.Type);
        Assert.Equal("Figure", tree.ElementFor(0, 2)!.Type);
        Assert.Null(tree.ElementFor(0, 9));
        Assert.Null(tree.ElementFor(5, 0));
    }

    [Fact]
    public void StandardTypeFollowsTheRoleMap()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        Assert.Equal("H1", tree.StandardType("Heading"));
        Assert.Equal("Nope", tree.StandardType("Weird"));
        Assert.Equal("P", tree.StandardType("P"));
        tree.RoleMap["A"] = "B";
        tree.RoleMap["B"] = "A";
        Assert.False(StructureTree.IsStandard(tree.StandardType("A")));
        Assert.True(StructureTree.IsStandard("H3"));
        Assert.False(StructureTree.IsStandard("H0"));
        Assert.False(StructureTree.IsStandard("Hx"));
    }

    [Fact]
    public void NoTreeReadsAsNull()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => ""));
        Assert.Null(StructureTree.Read(document));
    }

    [Fact]
    public void WritingWhatWasReadChangesNothing()
    {
        using var document = PdfDocument.Open(TaggedFile.Build());
        StructureTree.Read(document)!.Write(document);

        Assert.Empty(document.ChangedObjects());
    }

    [Fact]
    public void RetagAltAndLanguageSurviveASave()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var figure = tree.Elements.First(e => e.Type == "Figure");
        figure.Type = "Formula";
        figure.Alt = "x squared";
        figure.Lang = "en";
        tree.Elements.First(e => e.Type == "P").Type = "Div";
        tree.Write(document);

        foreach (bool rewrite in new[] { false, true })
        {
            using var again = AccessKit.Reopen(document, rewrite);
            var read = StructureTree.Read(again)!;
            Assert.Equal(["H1", "Div", "Formula"], read.Roots[0].Children.Select(c => c.Type));
            var formula = read.Elements.First(e => e.Type == "Formula");
            Assert.Equal("x squared", formula.Alt);
            Assert.Equal("en", formula.Lang);
            Assert.Equal("Formula", read.ElementFor(0, 2)!.Type);
        }
    }

    [Fact]
    public void UnknownKeysStay()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var h1 = tree.Elements.First(e => e.Type == "H1");
        h1.Alt = "changed";
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!.Elements.First(e => e.Type == "H1");
        Assert.Equal("Fancy", again.Name(read.Dictionary, "C"));
        Assert.Equal("Layout", again.Name(again.Dict(read.Dictionary, "A"), "O"));
        Assert.Equal("Block", again.Name(again.Dict(read.Dictionary, "A"), "Placement"));
    }

    [Fact]
    public void ReorderKeepsTheParentTreeRight()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var figure = tree.Elements.First(e => e.Type == "Figure");
        tree.Move(figure, tree.Roots[0], 0);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["Figure", "H1", "P"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal("Figure", read.ElementFor(0, 2)!.Type);
        Assert.Equal("H1", read.ElementFor(0, 0)!.Type);
    }

    [Fact]
    public void MoveInsideItselfIsRefused()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        var child = root.Children.First();

        Assert.Throws<ArgumentException>(() => tree.Move(root, child, 0));
        Assert.Throws<ArgumentException>(() => tree.Add(child, child));
        Assert.Throws<ArgumentException>(() => tree.Add(null, new StructContent(0, 3)));
    }

    [Fact]
    public void RemoveFreesTheObjectsAndEmptiesTheParentTreeSlot()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");
        int number = p.Reference!.Number;
        tree.Remove(p);
        tree.Write(document);

        Assert.Null(document.Get(number));
        var read = StructureTree.Read(document)!;
        Assert.Equal(["H1", "Figure"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Null(read.ElementFor(0, 1));
        Assert.Equal("Figure", read.ElementFor(0, 2)!.Type);
    }

    [Fact]
    public void AddedElementsGetObjectsAndParentTreeEntries()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, i => $"BT /F1 12 Tf 72 700 Td (page {i}) Tj ET"));
        var tree = StructureTree.Create(document);
        var root = new StructElement("Document");
        tree.Add(null, root);
        var first = new StructElement("P") { PageIndex = 0 };
        var second = new StructElement("P") { PageIndex = 1 };
        tree.Add(root, first);
        tree.Add(root, second);
        tree.Add(first, new StructContent(0, 0));
        tree.Add(second, new StructContent(1, 0));
        tree.Write(document);

        Assert.True(document.IsTagged);
        Assert.NotNull(first.Reference);
        var keys = document.Pages.Select(p => document.Integer(p.Dictionary, "StructParents")).ToList();
        Assert.All(keys, k => Assert.NotNull(k));
        Assert.NotEqual(keys[0], keys[1]);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(2, read.Roots[0].Children.Count());
        Assert.Equal(0, read.ElementFor(again.Integer(again.Pages[0].Dictionary, "StructParents")!.Value, 0)!.PageIndex);
        Assert.Equal(1, read.ElementFor(again.Integer(again.Pages[1].Dictionary, "StructParents")!.Value, 0)!.PageIndex);
    }

    [Fact]
    public void ContentOnAnotherPageThanTheElementsIsWrittenAsMcr()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, i => $"/P <</MCID 0>> BDC BT /F1 12 Tf 72 700 Td (page {i}) Tj ET EMC"));
        var tree = StructureTree.Create(document);
        var p = new StructElement("P") { PageIndex = 0 };
        tree.Add(null, p);
        tree.Add(p, new StructContent(0, 0));
        tree.Add(p, new StructContent(1, 0));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: false);
        var read = StructureTree.Read(again)!.Roots[0];
        Assert.Equal([0, 1], read.Kids.OfType<StructContent>().Select(k => k.PageIndex));
    }

    [Fact]
    public void ObjectReferencesGetAStructParent()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => "", pageEntries: "/Annots [8 0 R]", more: pdf =>
            pdf.Obj(8, "<</Type /Annot /Subtype /Link /Rect [72 700 144 712] /Border [0 0 0]>>")));
        var tree = StructureTree.Create(document);
        var link = new StructElement("Link") { PageIndex = 0 };
        tree.Add(null, link);
        tree.Add(link, new StructObject(0, new PdfReference(8, 0)));
        tree.Write(document);

        Assert.NotNull(document.Integer((PdfDictionary)document.Get(8)!, "StructParent"));
        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var target = Assert.IsType<StructObject>(Assert.Single(read.Roots[0].Kids));
        var annotation = (PdfDictionary)again.Resolve(target.Target)!;
        Assert.Equal("Link", read.ElementFor(again.Integer(annotation, "StructParent")!.Value, -1)!.Type);
    }

    [Fact]
    public void ParentTreeOfManyPagesIsSplitAndStillFindsEverything()
    {
        using var document = PdfDocument.Open(AccessKit.Build(70, i => $"BT /F1 12 Tf 72 700 Td (page {i}) Tj ET"));
        var tree = StructureTree.Create(document);
        var root = new StructElement("Document");
        tree.Add(null, root);
        for (int i = 0; i < 70; i++)
        {
            var p = new StructElement("P") { PageIndex = i };
            tree.Add(root, p);
            tree.Add(p, new StructContent(i, 0));
        }
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(70, read.ParentTree.Count);
        for (int i = 0; i < 70; i++)
        {
            Assert.Equal(i, read.ElementFor(again.Integer(again.Pages[i].Dictionary, "StructParents")!.Value, 0)!.PageIndex);
        }
    }

    [Fact]
    public void LoopsJunkAndMissingTypesAreTolerated()
    {
        using var document = TaggedFile.Open(o =>
        {
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 9 0 R -3 (junk) null 14 0 R <</S /Span /Pg 3 0 R /K 5>> 11 0 R 12 0 R 99 0 R]>>";
            o[14] = "<</Type /StructElem /P 9 0 R /K 15 0 R>>";
            o[15] = "<</Type /StructElem /S /Span /P 14 0 R /K [15 0 R 3 4]>>";
        });
        var tree = StructureTree.Read(document)!;

        var root = tree.Roots[0];
        Assert.Equal(["H1", "", "Span", "P", "Figure"], root.Children.Select(c => c.Type));
        var span = tree.Elements.First(e => e.Type == "Span" && e.Kids.OfType<StructContent>().Any(k => k.Mcid == 3));
        Assert.Equal([3, 4], span.Kids.OfType<StructContent>().Select(k => k.Mcid));
        Assert.False(tree.IsTruncated);
    }

    [Fact]
    public void ADeepChainIsCutAndRefusesToBeWritten()
    {
        using var document = TaggedFile.Open(o =>
        {
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K 100 0 R>>";
            for (int i = 100; i < 400; i++) o[i] = $"<</Type /StructElem /S /Div /K {i + 1} 0 R>>";
        });
        var tree = StructureTree.Read(document)!;

        Assert.True(tree.IsTruncated);
        Assert.True(tree.Elements.Count() < 200);
        Assert.Throws<InvalidOperationException>(() => tree.Write(document));
    }

    [Fact]
    public void KidsAreReadWithTheirPageFromMcrAndObjr()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, i => "", catalog: "/StructTreeRoot 8 0 R", more: pdf =>
        {
            pdf.Obj(8, "<</Type /StructTreeRoot /K 9 0 R>>");
            pdf.Obj(9, "<</S /Document /K [<</Type /MCR /Pg 4 0 R /MCID 7>> <</Type /OBJR /Pg 3 0 R /Obj 10 0 R>> <</Type /MCR /Pg 3 0 R /Stm 11 0 R /MCID 2>>]>>");
            pdf.Obj(10, "<</Type /Annot /Subtype /Widget /Rect [0 0 1 1]>>");
            pdf.Obj(11, "<</Type /XObject /Subtype /Form /BBox [0 0 1 1]>>");
        }));
        var kids = StructureTree.Read(document)!.Roots[0].Kids;

        var mcr = Assert.IsType<StructContent>(kids[0]);
        Assert.Equal((1, 7), (mcr.PageIndex, mcr.Mcid));
        var objr = Assert.IsType<StructObject>(kids[1]);
        Assert.Equal((0, 10), (objr.PageIndex, objr.Target.Number));
        Assert.Equal(11, Assert.IsType<StructContent>(kids[2]).Stream!.Number);
    }

    [Fact]
    public void ARemovedElementMovedBackKeepsItsObject()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var p = tree.Elements.First(e => e.Type == "P");
        int number = p.Reference!.Number;
        tree.Remove(p);
        tree.Move(p, tree.Roots[0], -1);
        tree.Write(document);

        Assert.NotNull(document.Get(number));
        var read = StructureTree.Read(document)!;
        Assert.Equal(["H1", "Figure", "P"], read.Roots[0].Children.Select(c => c.Type));
        Assert.Equal("P", read.ElementFor(0, 1)!.Type);
    }
}
