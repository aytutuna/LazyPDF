using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TagContentTests
{
    private const string Words = "BT /F1 11 Tf 72 700 Td (Hello world) Tj ET\nBT /F1 11 Tf 72 650 Td (Second line) Tj ET\n";

    // Object 3 is the page, 4 the font, 5 an image, 6 a form that draws "Label", streams are 20 and up, the tree 30 and up.
    private static byte[] Make(string[] streams, Action<TestPdf>? tree = null, int pages = 1, bool structure = false)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {(structure ? "/StructTreeRoot 30 0 R /MarkInfo <</Marked true>>" : "")} /Lang (en-US)>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{3 + 40 * i} 0 R"))}] /Count {pages} /MediaBox [0 0 612 792]>>");
        string contents = string.Join(" ", streams.Select((_, i) => $"{20 + i} 0 R"));
        for (int p = 0; p < pages; p++)
        {
            pdf.Obj(3 + 40 * p, $"<</Type /Page /Parent 2 0 R /Contents [{contents}] /Resources <</Font <</F1 4 0 R>> /XObject <</Im1 5 0 R /Fm1 6 0 R>> /Properties <</MC0 <</MCID 0 /Subtype /Footer /Type /Pagination>>>>>>{(structure && p == 0 ? " /StructParents 0" : "")}>>");
        }
        pdf.Obj(4, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 80, 160, 255]);
        pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 4 0 R>>>>", "BT /F1 11 Tf 300 300 Td (Label) Tj ET");
        for (int i = 0; i < streams.Length; i++) pdf.Stream(20 + i, "", streams[i]);
        tree?.Invoke(pdf);
        return pdf.Finish();
    }

    // Root 30 holds Document 31 with the given kids (object 32 on); /K of each is written by the caller.
    private static Action<TestPdf> Tree(params string[] elements) => pdf =>
    {
        pdf.Obj(30, "<</Type /StructTreeRoot /K 31 0 R /ParentTree 29 0 R>>");
        pdf.Obj(31, $"<</Type /StructElem /S /Document /P 30 0 R /K [{string.Join(" ", elements.Select((_, i) => $"{32 + i} 0 R"))}]>>");
        for (int i = 0; i < elements.Length; i++) pdf.Obj(32 + i, elements[i].Replace("PARENT", "31 0 R").Replace("PAGE", "3 0 R"));
        pdf.Obj(29, "<</Nums []>>");
    };

    private static string Drawing(PdfDocument document, int page = 0) =>
        string.Join("\n", ContentParser.Parse(document.Pages[page].Contents()).Where(o => o.Operator is not ("BMC" or "BDC" or "EMC")).Select(o => o.ToString()));

    private static string Kinds(StructElement element) =>
        string.Join(",", element.Kids.Select(k => k switch { StructElement e => $"{e.Type}({Kinds(e)})", StructContent c => "mcid" + c.Mcid, _ => "obj" }));

    private static string Tags(PdfDocument document, int page = 0) =>
        string.Join(" ", AccessKit.Sequences(document, page).Select(s => s.Mcid < 0 ? s.Tag : $"{s.Tag}:{s.Mcid}"));

    private static PdfDocument Open(byte[] bytes) => PdfDocument.Open(bytes);

    [Fact]
    public void MarkingAnElementAsArtifactRewritesItsSequenceAndDropsIt()
    {
        using var document = TaggedFile.Open();
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document)!;
        var p = AccessKit.Find(tree, "P")!;

        Assert.Null(tree.MarkAsArtifact(p));
        tree.Write(document);

        Assert.Equal("H1:0 Artifact Figure:2", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        Assert.Equal(["H1", "Figure"], read.Roots[0].Children.Select(c => c.Type));
        Assert.DoesNotContain("Body", ReadingOrder.Export(again));
        var array = Assert.IsType<PdfArray>(again.Resolve(Assert.Single(read.ParentTree).Value));
        Assert.Equal(3, array.Items.Count);
        Assert.IsType<PdfNull>(array.Items[1]);
    }

    [Fact]
    public void AnElementLeftEmptyIsDroppedButNotTheRoot()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        var content = AccessKit.Find(tree, "P")!.Kids.OfType<StructContent>().Single();

        Assert.Null(tree.MarkAsArtifact(content));

        Assert.Equal(["H1", "Figure"], tree.Roots[0].Children.Select(c => c.Type));
        foreach (var element in tree.Roots[0].Children.ToList()) Assert.Null(tree.MarkAsArtifact(element));
        Assert.Single(tree.Roots);
        Assert.Empty(tree.Roots[0].Kids);
        Assert.Equal("Artifact Artifact Artifact", Tags(document));
    }

    [Fact]
    public void AnElementWithSeveralContentsAndNestedElementsTakesAllOfThem()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj ET EMC /Span <</MCID 1>> BDC BT /F1 11 Tf 72 650 Td (B) Tj ET EMC /P <</MCID 2>> BDC BT /F1 11 Tf 72 600 Td (C) Tj ET EMC";
        using var document = Open(Make([content], Tree(
            "<</Type /StructElem /S /Div /P PARENT /Pg PAGE /K [0 33 0 R]>>",
            "<</Type /StructElem /S /Span /P 32 0 R /Pg PAGE /K 1>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 2>>"), structure: true));
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document)!;

        Assert.Null(tree.MarkAsArtifact(AccessKit.Find(tree, "Div")!));

        Assert.Equal("Artifact Artifact P:2", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.Equal(["P"], tree.Roots[0].Children.Select(c => c.Type));
    }

    [Fact]
    public void ArtifactPropertiesSurviveAndOtherKeysGo()
    {
        string content = "/Span /MC0 BDC BT /F1 11 Tf 72 700 Td (Footer) Tj ET EMC /P <</MCID 1 /Lang (en)>> BDC BT /F1 11 Tf 72 650 Td (B) Tj ET EMC";
        using var document = Open(Make([content], Tree(
            "<</Type /StructElem /S /Span /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 1>>"), structure: true));
        var tree = StructureTree.Read(document)!;

        Assert.Null(tree.MarkAsArtifact(tree.Roots[0]!.Children.First()));
        Assert.Null(tree.MarkAsArtifact(tree.Roots[0]!.Children.First()));

        string text = TestPdf.Text(document.Pages[0].Contents());
        Assert.Contains("/Artifact <</Type /Pagination /Subtype /Footer>> BDC", text);
        Assert.Contains("/Artifact BMC", text);
        Assert.DoesNotContain("MCID", text);
    }

    [Fact]
    public void TaggedContentInsideTheSequenceRefusesAndChangesNothing()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj /Span <</MCID 1>> BDC (B) Tj EMC ET EMC";
        using var document = Open(Make([content], Tree(
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /Span /P PARENT /Pg PAGE /K 1>>"), structure: true));
        var tree = StructureTree.Read(document)!;
        byte[] before = document.Pages[0].Contents();

        Assert.Equal(TagContent.NestedTagged, tree.MarkAsArtifact(tree.Roots[0].Children.First()));

        Assert.Equal(before, document.Pages[0].Contents());
        Assert.Equal(2, tree.Roots[0].Children.Count());
    }

    [Fact]
    public void ContentOfSeveralStreamsIsRewrittenInPlace()
    {
        string[] streams =
        [
            "/H1 <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Head) Tj ET EMC\n",
            "/P <</MCID 1>> BDC BT /F1 11 Tf 72 650 Td (Body) Tj ET\n",
            " EMC\n/P <</MCID 2>> BDC BT /F1 11 Tf 72 600 Td (Tail) Tj ET EMC\n",
        ];
        using var document = Open(Make(streams, Tree(
            "<</Type /StructElem /S /H1 /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 1>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 2>>"), structure: true));
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document)!;
        var parts = TagSession.Streams(document, document.Pages[0]);
        byte[] first = document.Data(parts[0]);

        Assert.Null(tree.MarkAsArtifact(tree.Roots[0].Children.ElementAt(1)));

        Assert.Equal("H1:0 Artifact P:2", Tags(document));
        Assert.Equal(first, document.Data(parts[0]));
        Assert.Equal(drawing, Drawing(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
    }

    [Fact]
    public void ASharedStreamAndFormContentAreRefused()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj ET EMC";
        Action<TestPdf> elements = Tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>");
        using var shared = Open(Make([content], elements, pages: 2, structure: true));
        var tree = StructureTree.Read(shared)!;

        Assert.Equal(TagContent.SharedStream, tree.MarkAsArtifact(tree.Roots[0].Children.First()));

        using var alone = Open(Make([content], elements, structure: true));
        var other = StructureTree.Read(alone)!;
        var inForm = new StructElement("P") { PageIndex = 0 };
        other.Add(other.Roots[0], inForm);
        other.Add(inForm, new StructContent(0, 0, new PdfReference(6, 0)));

        Assert.Equal(TagContent.FormContent, other.MarkAsArtifact(inForm));
        Assert.Equal(TagContent.NotContent, other.MarkAsArtifact(new StructObject(0, new PdfReference(3, 0))));
    }

    [Fact]
    public void ASelectionInAFileWithoutTagsMakesADocumentAndAnElement()
    {
        using var document = Open(Make([Words]));
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document) ?? StructureTree.Create(document);
        var line = TextPage.Create(document, document.Pages[0]).Lines[0].Range;

        var result = tree.TagSelection(0, [line], "P", null);

        Assert.Null(result.Reason);
        Assert.Equal("P(mcid0)", Kinds(tree.Roots[0]));
        Assert.Equal("P:0", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.NotNull(again.Pages[0].Dictionary["StructParents"]);
        Assert.Equal("Hello world", ReadingOrder.Export(again));
        Assert.Equal(["Document"], StructureTree.Read(again)!.Roots.Select(r => r.Type));
    }

    [Fact]
    public void ARoleMappedTypeWithASpaceAndALatinByteIsWrittenAsOneName()
    {
        using var document = Open(Make([Words]));
        var tree = StructureTree.Create(document);
        tree.RoleMap["Body Téxt"] = "P";
        var line = TextPage.Create(document, document.Pages[0]).Lines[0].Range;

        Assert.Null(tree.TagSelection(0, [line], "Body Téxt", null).Reason);

        var begin = ContentParser.Parse(document.Pages[0].Contents()).First(o => o.Operator == "BDC");
        Assert.Equal(2, begin.Operands.Count);
        Assert.Equal("Body Téxt", Assert.IsType<PdfName>(begin.Operands[0]).Value);
        Assert.Equal("Body Téxt:0", Tags(document));
    }

    [Fact]
    public void ASelectionThatCutsAStringIsRefusedWithTheContentUntouched()
    {
        using var document = Open(Make([Words]));
        var tree = StructureTree.Create(document);
        byte[] before = document.Pages[0].Contents();
        var word = TextPage.Create(document, document.Pages[0]).Words[0].Range;

        var result = tree.TagSelection(0, [word], "P", null);

        Assert.Equal(TagContent.SplitOperation, result.Reason);
        Assert.Equal(before, document.Pages[0].Contents());
        Assert.Empty(tree.Roots);
    }

    [Fact]
    public void TwoLinesOfOneTextObjectShareOneSequence()
    {
        string content = "BT /F1 11 Tf 72 700 Td (One) Tj 0 -14 Td (Two) Tj 0 -14 Td (Three) Tj ET\n";
        using var document = Open(Make([content]));
        string drawing = Drawing(document);
        var tree = StructureTree.Create(document);
        var lines = TextPage.Create(document, document.Pages[0]).Lines;

        var result = tree.TagSelection(0, [lines[0].Range, lines[1].Range], "P", null);

        Assert.Null(result.Reason);
        Assert.Equal("P:0", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
        Assert.DoesNotContain("Three) Tj\nET", TestPdf.Text(document.Pages[0].Contents()).Replace("Three) Tj ET", "x"));
    }

    [Fact]
    public void AnAreaTakesTheTextAndThePictureInsideItAndSkipsTheRest()
    {
        string content = Words + "q 50 0 0 50 72 560 cm /Im1 Do Q\n";
        using var document = Open(Make([content]));
        string drawing = Drawing(document);
        var tree = StructureTree.Create(document);

        var result = tree.TagArea(0, new PdfRect(60, 545, 200, 665), "Figure", null);

        Assert.Null(result.Reason);
        Assert.Equal("Figure:0 Figure:1", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.Equal("Figure(mcid0,mcid1)", Kinds(tree.Roots[0]));
        tree.Write(document);
        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.Equal("[Figure: Second line]", ReadingOrder.Export(again));
    }

    [Fact]
    public void AnAreaCuttingAnInlineImageIsRefused()
    {
        string content = "q 40 0 0 40 72 600 cm BI /W 2 /H 2 /CS /G /BPC 8 ID \0\x50\xA0\xFF EI Q\n";
        using var document = Open(Make([content]));
        var tree = StructureTree.Create(document);

        Assert.Equal(TagContent.SplitOperation, tree.TagArea(0, new PdfRect(0, 590, 90, 700), "Figure", null).Reason);
        Assert.Equal(TagContent.EmptySelection, tree.TagArea(0, new PdfRect(300, 100, 400, 200), "Figure", null).Reason);
        Assert.Null(tree.TagArea(0, new PdfRect(60, 590, 120, 700), "Figure", null).Reason);
    }

    [Fact]
    public void AWholeTaggedSequenceMovesToTheNewElementAndItsOldElementGoes()
    {
        using var document = TaggedFile.Open();
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document)!;
        var content = TextPage.Create(document, document.Pages[0]).Lines.Where(l => l.Text == "Body text").Single().Range;

        var result = tree.TagSelection(0, [content], "BlockQuote", tree.Roots[0], 0);

        Assert.Null(result.Reason);
        Assert.Equal("BlockQuote(mcid1),H1(mcid0),Figure(mcid2)", Kinds(tree.Roots[0]));
        Assert.Equal("H1:0 P:1 Figure:2", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        tree.Write(document);
        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.Equal(["BlockQuote", "H1", "Figure"], StructureTree.Read(again)!.Roots[0].Children.Select(c => c.Type));
    }

    [Fact]
    public void PartOfATaggedSequenceIsRefused()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (One) Tj 0 -14 Td (Two) Tj ET EMC\n";
        using var document = Open(Make([content], Tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true));
        var tree = StructureTree.Read(document)!;
        byte[] before = document.Pages[0].Contents();
        var first = TextPage.Create(document, document.Pages[0]).Lines[0].Range;

        var result = tree.TagSelection(0, [first], "Quote", tree.Roots[0]);

        Assert.Equal(TagContent.PartialMarked, result.Reason);
        Assert.Equal(before, document.Pages[0].Contents());
        Assert.Equal("P", string.Join(",", tree.Roots[0].Children.Select(c => c.Type)));
    }

    [Fact]
    public void AnArtifactSequenceTakesAFreshNumberWhenPickedWhole()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Body) Tj ET EMC\n/Artifact <</Type /Pagination>> BDC BT /F1 9 Tf 72 30 Td (Page 1) Tj ET EMC\n/Artifact BMC BT /F1 9 Tf 72 20 Td (Other) Tj ET EMC\n";
        using var document = Open(Make([content], Tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true));
        string drawing = Drawing(document);
        var tree = StructureTree.Read(document)!;
        var footer = TextPage.Create(document, document.Pages[0]).Lines.Single(l => l.Text == "Page 1").Range;

        var result = tree.TagSelection(0, [footer], "P", tree.Roots[0]);

        Assert.Null(result.Reason);
        Assert.Equal("P:0 P:1 Artifact", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
        Assert.Equal("P(mcid0),P(mcid1)", Kinds(tree.Roots[0]));
    }

    [Fact]
    public void AnOpenSequenceTheTreeDoesNotNameIsClaimedAndNewNumbersSkipUsedOnes()
    {
        string content = "/P <</MCID 3>> BDC BT /F1 11 Tf 72 700 Td (Stray) Tj ET EMC\nBT /F1 11 Tf 72 650 Td (Loose) Tj ET\n";
        using var document = Open(Make([content]));
        var tree = StructureTree.Create(document);
        var lines = TextPage.Create(document, document.Pages[0]).Lines;

        var result = tree.TagSelection(0, [lines[0].Range, lines[1].Range], "Div", null);

        Assert.Null(result.Reason);
        Assert.Equal("Div:1 Div:0", Tags(document));
        Assert.Equal("Div(mcid1,mcid0)", Kinds(tree.Roots[0]));
    }

    [Fact]
    public void LooseContentInsideAnOpenLayerKeepsTheLayerBalanced()
    {
        string content = "/OC <</Layer 1>> BDC BT /F1 11 Tf 72 700 Td (Inside) Tj ET EMC\n";
        using var document = Open(Make([content]));
        string drawing = Drawing(document);
        var tree = StructureTree.Create(document);

        Assert.Null(tree.TagSelection(0, [new TextRange(0, 6)], "P", null).Reason);

        Assert.Equal("OC P:0", Tags(document));
        Assert.Equal(drawing, Drawing(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
    }

    [Fact]
    public void ContentOfALaterStreamIsTaggedThere()
    {
        string[] streams = ["BT /F1 11 Tf 72 700 Td (Head) Tj ET\n", "BT /F1 11 Tf 72 650 Td (Tail) Tj ET\n"];
        using var document = Open(Make(streams));
        string drawing = Drawing(document);
        var tree = StructureTree.Create(document);
        var parts = TagSession.Streams(document, document.Pages[0]);
        byte[] first = document.Data(parts[0]);
        var tail = TextPage.Create(document, document.Pages[0]).Lines.Single(l => l.Text == "Tail").Range;

        Assert.Null(tree.TagSelection(0, [tail], "P", null).Reason);

        Assert.Equal(first, document.Data(parts[0]));
        Assert.Equal("P:0", Tags(document));
        Assert.Equal(drawing, Drawing(document));
    }

    [Fact]
    public void FormContentAndSharedStreamsAreRefusedForASelection()
    {
        string content = "q 1 0 0 1 0 0 cm /Fm1 Do Q\n";
        using var document = Open(Make([content]));
        var tree = StructureTree.Create(document);
        var all = new TextRange(0, TextPage.Create(document, document.Pages[0]).Chars.Count);

        Assert.Equal(TagContent.FormContent, tree.TagSelection(0, [all], "P", null).Reason);
        Assert.Null(tree.TagArea(0, new PdfRect(0, 0, 612, 792), "P", null).Reason);

        using var shared = Open(Make([Words], pages: 2));
        Assert.Equal(TagContent.SharedStream, StructureTree.Create(shared).TagArea(0, new PdfRect(0, 0, 612, 792), "P", null).Reason);
    }

    [Theory]
    [InlineData("TR", TagRules.NeedsTableOrPart)]
    [InlineData("Table", TagRules.NoContent)]
    [InlineData("Link", TagRules.LinkObject)]
    [InlineData("Nonsense", TagRules.Unmapped)]
    public void ATypeThatCannotHoldContentOrFitItsParentIsRefused(string type, string reason)
    {
        using var document = Open(Make([Words]));
        var tree = StructureTree.Create(document);
        byte[] before = document.Pages[0].Contents();

        Assert.Equal(reason, tree.TagArea(0, new PdfRect(0, 0, 612, 792), type, null).Reason);
        Assert.Equal(before, document.Pages[0].Contents());
    }

    [Fact]
    public void AParentOrElementOutsideTheTreeIsRefused()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        Assert.Equal(TagContent.NotInTree, tree.TagArea(0, new PdfRect(0, 0, 612, 792), "P", new StructElement("Div")).Reason);
        Assert.Equal(TagContent.NotInTree, tree.MarkAsArtifact(new StructElement("P")));
    }

    [Fact]
    public void BoxesFollowWhatTheSequencesDraw()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;

        var body = tree.Boxes(AccessKit.Find(tree, "P")!);
        var figure = tree.Boxes(AccessKit.Find(tree, "Figure")!);
        var all = tree.Boxes(tree.Roots[0]);

        var box = Assert.Single(body.Boxes).Rect;
        Assert.InRange(box.Left, 71, 73);
        Assert.True(box.Bottom < 670 && box.Top > 670 && box.Right > 110);
        Assert.Equal(new PdfRect(72, 600, 122, 650), Assert.Single(figure.Boxes).Rect);
        Assert.Equal(3, all.Boxes.Count);
        Assert.False(all.IsCapped);
        Assert.All(all.Boxes, b => Assert.Equal(0, b.PageIndex));
    }

    [Fact]
    public void BoxesIncludeFormsDrawnInsideASequenceAndAnnotationRects()
    {
        string content = "/P <</MCID 0>> BDC /Fm1 Do EMC";
        using var document = Open(Make([content], Tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true));
        var tree = StructureTree.Read(document)!;
        var annotation = document.Add(new PdfDictionary { ["Type"] = new PdfName("Annot"), ["Subtype"] = new PdfName("Link"), ["Rect"] = new PdfRect(10, 20, 110, 40).ToArray() });
        var link = new StructElement("Link") { PageIndex = 0 };
        tree.Add(tree.Roots[0], link);
        tree.Add(link, new StructObject(0, annotation));

        var boxes = tree.Boxes(tree.Roots[0]).Boxes;

        Assert.Equal(2, boxes.Count);
        Assert.InRange(boxes[0].Rect.Left, 299, 301);
        Assert.Equal(new PdfRect(10, 20, 110, 40), boxes[1].Rect);
    }

    [Fact]
    public void BoxesStopAtTheCap()
    {
        string content = string.Concat(Enumerable.Range(0, 600).Select(i => $"/Span <</MCID {i}>> BDC BT /F1 6 Tf 10 {700 - i} Td (x) Tj ET EMC\n"));
        using var document = Open(Make([content], Tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE>>"), structure: true));
        var tree = StructureTree.Read(document)!;
        for (int i = 0; i < 600; i++) tree.Add(tree.Roots[0].Children.First(), new StructContent(0, i));

        var boxes = tree.Boxes(tree.Roots[0]);

        Assert.Equal(500, boxes.Boxes.Count);
        Assert.True(boxes.IsCapped);
    }
}
