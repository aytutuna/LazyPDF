using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AutoTaggerTests
{
    private static string Shape(StructElement e) =>
        e.Type + (e.Children.Any() ? "(" + string.Join(",", e.Children.Select(Shape)) + ")" : "");

    [Fact]
    public void ReportPageGetsHeadingsParagraphsListTableAndFigure()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        var result = AutoTagger.Tag(document);

        Assert.Equal((1, 0, 1, 3, 1, 1, 1), (result.Pages, result.SkippedPages, result.Headings, result.Paragraphs, result.Lists, result.Tables, result.Figures));
        var tree = StructureTree.Read(document)!;
        Assert.Equal(
            "Document(P,H1,P,P,L(LI(Lbl,LBody),LI(Lbl,LBody),LI(Lbl,LBody)),Table(TR(TH,TH,TH),TR(TD,TD,TD),TR(TD,TD,TD)),Figure)",
            Shape(tree.Roots[0]));
        Assert.True(document.IsTagged);
        Assert.Equal("S", document.Name(document.Pages[0].Dictionary, "Tabs"));
    }

    [Fact]
    public void RoundTripKeepsEverySequenceInTheParentTree()
    {
        using var document = PdfDocument.Open(AccessKit.Report(3));
        string[] before = [.. Enumerable.Range(0, 3).Select(i => AccessKit.Plain(document, i))];
        string[] pig = [.. Enumerable.Range(1, 3).Select(i => AccessKit.PigText(document.SaveIncremental(), i))];
        AutoTagger.Tag(document);

        foreach (bool rewrite in new[] { false, true })
        {
            var bytes = rewrite ? document.SaveRewrite() : document.SaveIncremental();
            using var again = PdfDocument.Open(bytes);
            var tree = StructureTree.Read(again)!;
            Assert.False(tree.IsTruncated);
            for (int p = 0; p < 3; p++)
            {
                Assert.Equal(before[p], AccessKit.Plain(again, p));
                Assert.Equal(pig[p], AccessKit.PigText(bytes, p + 1));
                Assert.True(AccessKit.IsBalanced(again, p));

                var inContent = AccessKit.Sequences(again, p).Where(s => s.Mcid >= 0).ToList();
                var inTree = tree.Contents.Where(c => c.PageIndex == p).ToList();
                Assert.Equal(inContent.Select(s => s.Mcid).Order(), inTree.Select(c => c.Mcid).Order());
                Assert.Equal(inContent.Count, inContent.Select(s => s.Mcid).Distinct().Count());

                long key = again.Integer(again.Pages[p].Dictionary, "StructParents")!.Value;
                foreach (var (tag, mcid) in inContent)
                {
                    var owner = tree.ElementFor(key, mcid)!;
                    Assert.Equal(tag, owner.Type);
                    Assert.Contains(owner.Kids.OfType<StructContent>(), c => c.PageIndex == p && c.Mcid == mcid);
                }
            }
        }
    }

    [Fact]
    public void HeaderFooterAndPageNumbersBecomeArtifacts()
    {
        using var document = PdfDocument.Open(AccessKit.Report(3));
        AutoTagger.Tag(document);

        string read = ReadingOrder.Export(document);
        Assert.DoesNotContain("ACME", read);
        Assert.DoesNotContain("Page 2", read);
        Assert.Contains("Introduction", read);
        var content = ContentParser.Parse(document.Pages[1].Contents());
        var artifacts = content.Where(o => o.Operator == "BMC" && o.Operands[0] is PdfName { Value: "Artifact" }).ToList();
        Assert.Equal(3, artifacts.Count);
    }

    [Fact]
    public void RotatedPagesAreTagged()
    {
        using var document = PdfDocument.Open(AccessKit.Build(3, AccessKit.ReportPage, pageEntries: "/Rotate 90"));
        string before = AccessKit.Plain(document, 1);
        var result = AutoTagger.Tag(document);

        Assert.Equal((3, 3, 3, 3), (result.Pages, result.Headings, result.Lists, result.Tables));
        Assert.Equal(before, AccessKit.Plain(document, 1));
    }

    [Fact]
    public void ASinglePageKeepsItsHeaderButNotItsNumber()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        AutoTagger.Tag(document);

        string read = ReadingOrder.Export(document);
        Assert.Contains("ACME Quarterly Report", read);
        Assert.DoesNotContain("Page 1", read);
    }

    [Fact]
    public void HeadingLevelsFollowSizeAndNeverSkip()
    {
        string Page(int i) =>
            AccessKit.Text(72, 720, "Chapter One", 24, bold: true) +
            AccessKit.Text(72, 690, "Section A", 16, bold: true) +
            AccessKit.Text(72, 660, "Body text goes here and runs long enough to be the body.") +
            AccessKit.Text(72, 640, "More body text follows on the next line of the page.") +
            AccessKit.Text(72, 600, "Detail", 11, bold: true) +
            AccessKit.Text(72, 580, "Body text again, a sentence that is not bold at all.");
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        AutoTagger.Tag(document);

        var types = StructureTree.Read(document)!.Elements.Select(e => e.Type).Where(t => t.StartsWith('H')).ToList();
        Assert.Equal(["H1", "H2", "H3"], types);
    }

    [Fact]
    public void NumberedListsAreRecognised()
    {
        string Page(int i) =>
            AccessKit.Text(72, 700, "1. Open the file") + AccessKit.Text(72, 686, "2. Choose a name") + AccessKit.Text(72, 672, "3. Save it") +
            AccessKit.Text(72, 600, "Plain text that is not a list at all, only a sentence.");
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        var result = AutoTagger.Tag(document);

        Assert.Equal(1, result.Lists);
        var list = StructureTree.Read(document)!.Elements.First(e => e.Type == "L");
        Assert.Equal(3, list.Children.Count());
        Assert.All(list.Children, li => Assert.Equal(["LBody"], li.Children.Select(c => c.Type)));
    }

    [Fact]
    public void ASeparateLabelBecomesLbl()
    {
        string Page(int i) =>
            "BT /F1 11 Tf 72 700 Td (1.) Tj 14 0 Td (Open the file) Tj ET BT /F1 11 Tf 72 686 Td (2.) Tj 14 0 Td (Choose a name) Tj ET";
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        AutoTagger.Tag(document);

        var list = StructureTree.Read(document)!.Elements.First(e => e.Type == "L");
        Assert.All(list.Children, li => Assert.Equal(["Lbl", "LBody"], li.Children.Select(c => c.Type)));
    }

    [Fact]
    public void ALoneNumberedLineIsNotAList()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => AccessKit.Text(72, 700, "1. Only one such line in this text")));
        var result = AutoTagger.Tag(document);

        Assert.Equal(0, result.Lists);
        Assert.Equal(1, result.Paragraphs);
    }

    [Fact]
    public void RowsOfUnequalWidthAreNotATable()
    {
        string Page(int i) =>
            AccessKit.Text(72, 700, "Aa") + AccessKit.Text(222, 700, "Bb") + AccessKit.Text(372, 700, "Cc") +
            AccessKit.Text(72, 684, "Dd") + AccessKit.Text(222, 684, "Ee") +
            AccessKit.Text(72, 668, "Ff") + AccessKit.Text(222, 668, "Gg") + AccessKit.Text(372, 668, "Hh");
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        var result = AutoTagger.Tag(document);

        Assert.Equal(0, result.Tables);
        Assert.DoesNotContain(StructureTree.Read(document)!.Elements, e => e.Type is "Table" or "TR");
    }

    [Fact]
    public void FiguresWithoutAltAreReported()
    {
        using var document = PdfDocument.Open(AccessKit.Report(2));
        var result = AutoTagger.Tag(document);

        Assert.Equal(2, result.FiguresWithoutAlt.Count);
        var tree = StructureTree.Read(document)!;
        foreach (var figure in result.FiguresWithoutAlt)
        {
            var element = tree.Elements.First(e => e.Reference?.Number == figure.Reference.Number);
            Assert.Equal("Figure", element.Type);
            Assert.Null(element.Alt);
            Assert.Equal(figure.PageIndex, element.PageIndex);
        }
    }

    [Fact]
    public void ATaggedDocumentIsLeftAlone()
    {
        var bytes = TaggedFile.Build();
        using var document = PdfDocument.Open(bytes);
        var result = AutoTagger.Tag(document);

        Assert.True(result.AlreadyTagged);
        Assert.Empty(document.ChangedObjects());
    }

    [Fact]
    public void LanguageIsSetOnlyWhenMissing()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        AutoTagger.Tag(document, new AutoTagOptions("tr-TR"));
        Assert.Equal("tr-TR", PdfText.Read(document, document.Catalog, "Lang"));

        using var other = PdfDocument.Open(AccessKit.Build(1, AccessKit.ReportPage, catalog: "/Lang (de)"));
        AutoTagger.Tag(other, new AutoTagOptions("tr-TR"));
        Assert.Equal("de", PdfText.Read(other, other.Catalog, "Lang"));
    }

    [Fact]
    public void ExistingArtifactsAndOptionalContentAreKept()
    {
        string Page(int i) =>
            "/Artifact BMC 0.5 g 0 0 612 20 re f EMC\n" +
            "/OC /MC0 BDC " + AccessKit.Text(72, 700, "Layered text inside optional content") + "EMC\n" +
            "/Artifact <</Type /Pagination>> BDC " + AccessKit.Text(72, 760, "Stamped words") + "EMC\n" +
            AccessKit.Text(72, 650, "Ordinary text of the page, a full sentence.");
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        string before = AccessKit.Plain(document, 0);
        AutoTagger.Tag(document);

        Assert.Equal(before, AccessKit.Plain(document, 0));
        Assert.True(AccessKit.IsBalanced(document, 0));
        string read = ReadingOrder.Export(document);
        Assert.Contains("Layered text inside optional content", read);
        Assert.Contains("Ordinary text", read);
        Assert.DoesNotContain("Stamped", read);
        var sequences = AccessKit.Sequences(document, 0);
        Assert.Equal(2, sequences.Count(s => s.Tag == "Artifact"));
        Assert.Contains(sequences, s => s.Tag == "OC");
    }

    [Fact]
    public void ContentSplitOverSeveralStreamsStaysSplit()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => AccessKit.Text(72, 700, "First stream opens the page with a sentence.")));
        var page = document.Pages[0];
        
        var second = document.Add(new PdfStream(new PdfDictionary(), TestPdf.Latin(AccessKit.Text(72, 300, "Text from the second stream of the page."))));
        page.Dictionary["Contents"] = new PdfArray([page.Dictionary["Contents"]!, second]);
        string before = AccessKit.Plain(document, 0);

        var result = AutoTagger.Tag(document);

        Assert.Equal(1, result.Pages);
        Assert.Equal(2, ((PdfArray)document.Resolve(page.Dictionary["Contents"])!).Items.Count);
        Assert.Equal(before, AccessKit.Plain(document, 0));
        Assert.True(AccessKit.IsBalanced(document, 0));
        Assert.Contains("second stream", ReadingOrder.Export(document));
    }

    [Fact]
    public void AnOperatorInALaterStreamThanItsOperandsIsJoined()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => "BT /F1 12 Tf 72 700 Td (Split text of a sentence)"));
        var page = document.Pages[0];
        var second = document.Add(new PdfStream(new PdfDictionary(), TestPdf.Latin(" Tj ET\n" + AccessKit.Text(72, 600, "A later sentence."))));
        page.Dictionary["Contents"] = new PdfArray([page.Dictionary["Contents"]!, second]);
        string before = AccessKit.Plain(document, 0);

        var result = AutoTagger.Tag(document);

        Assert.Equal(1, result.Pages);
        Assert.IsType<PdfReference>(page.Dictionary["Contents"]);
        Assert.Equal(before, AccessKit.Plain(document, 0));
        Assert.Equal(2, AccessKit.Sequences(document, 0).Count(s => s.Mcid >= 0));
        Assert.Contains("Split text of a sentence", ReadingOrder.Export(document));
    }

    [Fact]
    public void TextInAFormIsTaggedAroundItsDo()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1,
            _ => AccessKit.Text(72, 700, "Page level words in a sentence.") + "/Fm1 Do\n",
            more: pdf =>
            {
                pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", AccessKit.Text(72, 500, "Words drawn by a form object."));
            }));
        var page = document.Pages[0];
        document.Dict(page.Resources, "XObject")!["Fm1"] = new PdfReference(8, 0);
        string before = AccessKit.Plain(document, 0);

        AutoTagger.Tag(document);

        Assert.Equal(before, AccessKit.Plain(document, 0));
        Assert.Contains("Words drawn by a form object.", ReadingOrder.Export(document));
        Assert.True(AccessKit.IsBalanced(document, 0));
    }

    [Fact]
    public void ASharedContentStreamLeavesBothPagesUntagged()
    {
        var bytes = AccessKit.Build(2, i => "", more: null);
        using var document = PdfDocument.Open(bytes);
        document.Pages[1].Dictionary["Contents"] = document.Pages[0].Dictionary["Contents"]!;
        ((PdfStream)document.Resolve(document.Pages[0].Dictionary["Contents"])!).Data = TestPdf.Latin(AccessKit.Text(72, 700, "Shared words."));

        var result = AutoTagger.Tag(document);

        Assert.Equal((0, 2), (result.Pages, result.SkippedPages));
        Assert.False(document.IsTagged);
    }

    [Fact]
    public void BrokenContentDoesNotStopTheTagger()
    {
        string Page(int i) =>
            "q q q 1 0 0 1 0 0 cm\n" + AccessKit.Text(72, 700, "Text after open saves, one sentence.") + "EMC EMC Q\n/Span BMC " +
            AccessKit.Text(72, 650, "Text in marked content that never ends.") + "[(unclosed";
        using var document = PdfDocument.Open(AccessKit.Build(1, Page));
        string before = AccessKit.Plain(document, 0);
        var result = AutoTagger.Tag(document);

        Assert.Equal(before, AccessKit.Plain(document, 0));
        Assert.Equal(1, result.Pages + result.SkippedPages);
    }

    [Fact]
    public void BlankAndEmptyPagesAreTaggedWithoutContent()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, i => i == 0 ? "" : "0.9 g 0 0 612 792 re f\n"));
        var result = AutoTagger.Tag(document);

        Assert.Equal((2, 0), (result.Pages, result.SkippedPages));
        Assert.True(document.IsTagged);
        Assert.Equal(1, result.Artifacts);
    }

    [Fact]
    public void LinksAndWidgetsGetElementsWithObjectReferences()
    {
        string page = AccessKit.Text(72, 700, "Visit the Lazy site for more.") + AccessKit.Text(72, 600, "Name:");
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => page, pageEntries: "/Annots [8 0 R 9 0 R]", more: pdf =>
        {
            pdf.Obj(8, "<</Type /Annot /Subtype /Link /Rect [114 695 138 711] /Border [0 0 0] /A <</S /URI /URI (https://example.org/)>>>>");
            pdf.Obj(9, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [120 590 220 612]>>");
        }));
        AutoTagger.Tag(document);

        var tree = StructureTree.Read(document)!;
        var link = tree.Elements.First(e => e.Type == "Link");
        Assert.Equal("Lazy", link.Alt);
        Assert.Equal(8, Assert.IsType<StructObject>(Assert.Single(link.Kids)).Target.Number);
        Assert.Equal("Lazy", PdfText.Read(document, (PdfDictionary)document.Get(8)!, "Contents"));
        var form = tree.Elements.First(e => e.Type == "Form");
        Assert.Equal(9, Assert.IsType<StructObject>(Assert.Single(form.Kids)).Target.Number);
        Assert.Equal("Link", tree.ElementFor(document.Integer((PdfDictionary)document.Get(8)!, "StructParent")!.Value, -1)!.Type);
    }

    [Fact]
    public void ALinkWithoutTextUnderItFallsBackToItsAddress()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => "", pageEntries: "/Annots [8 0 R]", more: pdf =>
            pdf.Obj(8, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (https://example.org/)>>>>")));
        AutoTagger.Tag(document);

        Assert.Equal("https://example.org/", StructureTree.Read(document)!.Elements.First(e => e.Type == "Link").Alt);
    }

    [Fact]
    public void ManyPagesGetAWholeParentTree()
    {
        using var document = PdfDocument.Open(AccessKit.Build(70, i => AccessKit.Text(72, 700, $"Page body {i} with a sentence of words.")));
        var result = AutoTagger.Tag(document);

        Assert.Equal(70, result.Pages);
        using var again = AccessKit.Reopen(document, rewrite: true);
        var tree = StructureTree.Read(again)!;
        Assert.Equal(70, tree.ParentTree.Count);
        Assert.Equal(70, tree.Contents.Count());
    }

    [Fact]
    public void AnEncryptedFileIsTaggedAndSavedEncrypted()
    {
        using var plain = PdfDocument.Open(AccessKit.Report(2));
        var id = new byte[16];
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id);
        var encrypted = plain.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));

        using var document = PdfDocument.Open(encrypted, "user");
        var result = AutoTagger.Tag(document);
        var saved = document.SaveIncremental();

        Assert.Equal(2, result.Pages);
        using var again = PdfDocument.Open(saved, "user");
        Assert.True(again.IsTagged);
        Assert.Contains("Introduction", ReadingOrder.Export(again));
    }

    [Fact]
    public void CancellationIsHonoured()
    {
        using var document = PdfDocument.Open(AccessKit.Report(3));
        using var source = new CancellationTokenSource();
        source.Cancel();

        Assert.Throws<OperationCanceledException>(() => AutoTagger.Tag(document, cancel: source.Token));
        Assert.False(document.IsTagged);
    }

    [Fact]
    public void WritingTheTreeMakesNoSecondTreeWhenTaggedTwice()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        AutoTagger.Tag(document);
        int objects = document.ObjectNumbers.Count;

        Assert.True(AutoTagger.Tag(document).AlreadyTagged);
        Assert.Equal(objects, document.ObjectNumbers.Count);
    }
}
