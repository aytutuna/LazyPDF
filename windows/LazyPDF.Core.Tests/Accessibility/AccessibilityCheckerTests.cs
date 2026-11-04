using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AccessibilityCheckerTests
{
    private static AccessibilityReport Check(Action<SortedDictionary<int, string>>? edit = null, string catalog = "/Lang (en-US)", string? content = null) =>
        AccessibilityChecker.Check(PdfDocument.Open(TaggedFile.Build(edit, catalog, content ?? TaggedFile.Content)));

    private static void AssertRule(AccessibilityReport report, AccessibilityRule rule, AccessibilityStatus status)
    {
        var item = report[rule];
        Assert.True(item.Status == status, $"{rule}: {item.Status} - {item.Message}");
        Assert.False(string.IsNullOrWhiteSpace(item.Message));
        Assert.Equal(AccessibilityText.Name(rule), item.Name);
    }

    [Fact]
    public void AGoodTaggedFilePassesEverythingButTheTitleAndContrast()
    {
        var report = Check();

        foreach (var item in report.Items)
        {
            var expected = item.Rule switch
            {
                AccessibilityRule.Title => AccessibilityStatus.Failed,
                AccessibilityRule.Contrast => AccessibilityStatus.NeedsPerson,
                _ => AccessibilityStatus.Passed,
            };
            Assert.True(item.Status == expected, $"{item.Rule}: {item.Status} - {item.Message}");
        }
        Assert.Equal(Enum.GetValues<AccessibilityRule>().Length, report.Items.Count);
        Assert.Equal((1, 1), (report.Failed, report.NeedsPerson));
    }

    [Fact]
    public void AnUntaggedFileFailsTheBasicsAndLeavesStructureToAPerson()
    {
        var report = AccessibilityChecker.Check(PdfDocument.Open(AccessKit.Report(1)));

        AssertRule(report, AccessibilityRule.Tagged, AccessibilityStatus.Failed);
        AssertRule(report, AccessibilityRule.Title, AccessibilityStatus.Failed);
        AssertRule(report, AccessibilityRule.Language, AccessibilityStatus.Failed);
        AssertRule(report, AccessibilityRule.TaggedContent, AccessibilityStatus.NeedsPerson);
        foreach (var rule in new[] { AccessibilityRule.FigureAlt, AccessibilityRule.TableHeaders, AccessibilityRule.ListStructure, AccessibilityRule.HeadingOrder, AccessibilityRule.Links })
        {
            AssertRule(report, rule, AccessibilityStatus.NeedsPerson);
        }
        AssertRule(report, AccessibilityRule.Searchable, AccessibilityStatus.Passed);
        AssertRule(report, AccessibilityRule.Encoding, AccessibilityStatus.Passed);
    }

    [Fact]
    public void ASuspectMarkFailsTheTaggedRule()
    {
        using var document = PdfDocument.Open(TaggedFile.Build());
        AssertRule(AccessibilityChecker.Check(document), AccessibilityRule.Tagged, AccessibilityStatus.Passed);

        document.Dict(document.Catalog, "MarkInfo")!["Suspects"] = new PdfBoolean(true);
        AssertRule(AccessibilityChecker.Check(document), AccessibilityRule.Tagged, AccessibilityStatus.Failed);
    }

    [Fact]
    public void TitleAndLanguageFixesMakeTheirRulesPass()
    {
        using var document = PdfDocument.Open(TaggedFile.Build(catalog: ""));
        var report = AccessibilityChecker.Check(document);
        Assert.Equal(AccessibilityFix.SetTitle, report[AccessibilityRule.Title].Fix);
        Assert.Equal(AccessibilityFix.SetLanguage, report[AccessibilityRule.Language].Fix);

        Assert.True(AccessibilityChecker.Fix(document, AccessibilityFix.SetTitle, "Annual plan"));
        Assert.True(AccessibilityChecker.Fix(document, AccessibilityFix.SetLanguage, "tr-TR"));

        using var again = AccessKit.Reopen(document, rewrite: false);
        var fixedReport = AccessibilityChecker.Check(again);
        AssertRule(fixedReport, AccessibilityRule.Title, AccessibilityStatus.Passed);
        AssertRule(fixedReport, AccessibilityRule.Language, AccessibilityStatus.Passed);
        Assert.Equal("Annual plan", DocumentMetadata.Read(again).Title);
    }

    [Fact]
    public void ATitleThatTheWindowDoesNotShowOffersTheShowFix()
    {
        using var document = PdfDocument.Open(TaggedFile.Build());
        (DocumentMetadata.Read(document) with { Title = "Has a title" }).Write(document);

        var item = AccessibilityChecker.Check(document)[AccessibilityRule.Title];
        Assert.Equal((AccessibilityStatus.Failed, AccessibilityFix.ShowTitle), (item.Status, item.Fix));
        Assert.True(AccessibilityChecker.Fix(document, AccessibilityFix.ShowTitle));
        Assert.False(AccessibilityChecker.Fix(document, AccessibilityFix.ShowTitle));
        AssertRule(AccessibilityChecker.Check(document), AccessibilityRule.Title, AccessibilityStatus.Passed);
    }

    [Fact]
    public void FixesRefuseMissingValues()
    {
        using var document = PdfDocument.Open(TaggedFile.Build());

        Assert.Throws<ArgumentException>(() => AccessibilityChecker.Fix(document, AccessibilityFix.SetTitle, "  "));
        Assert.Throws<ArgumentException>(() => AccessibilityChecker.Fix(document, AccessibilityFix.SetLanguage, "not a tag"));
        Assert.Throws<ArgumentException>(() => AccessibilityChecker.Fix(document, AccessibilityFix.SetLanguage));
        Assert.False(AccessibilityChecker.Fix(document, AccessibilityFix.None));
        Assert.False(AccessibilityChecker.Fix(document, AccessibilityFix.ShowTitle));
    }

    [Fact]
    public void TabOrderFailsOnPagesWithAnnotationsUntilFixed()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, _ => "", pageEntries: "", more: null));
        document.Pages[1].Dictionary["Annots"] = new PdfArray([document.Add(new PdfDictionary { ["Subtype"] = new PdfName("Text"), ["Rect"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(9), new PdfNumber(9)]) })]);

        var item = AccessibilityChecker.Check(document)[AccessibilityRule.TabOrder];
        Assert.Equal((AccessibilityStatus.Failed, AccessibilityFix.SetTabOrder), (item.Status, item.Fix));
        Assert.Equal(1, Assert.Single(item.Where).PageIndex);
        Assert.Contains("page 2", item.Message);

        Assert.True(AccessibilityChecker.Fix(document, AccessibilityFix.SetTabOrder));
        Assert.False(AccessibilityChecker.Fix(document, AccessibilityFix.SetTabOrder));
        Assert.Equal("S", document.Name(document.Pages[1].Dictionary, "Tabs"));
        Assert.Null(document.Name(document.Pages[0].Dictionary, "Tabs"));
        AssertRule(AccessibilityChecker.Check(document), AccessibilityRule.TabOrder, AccessibilityStatus.Passed);
    }

    [Fact]
    public void LongDocumentsNeedBookmarks()
    {
        Func<int, string> page = _ => AccessKit.Text(72, 700, "A page.");
        AssertRule(AccessibilityChecker.Check(PdfDocument.Open(AccessKit.Build(20, page))), AccessibilityRule.Bookmarks, AccessibilityStatus.Passed);
        AssertRule(AccessibilityChecker.Check(PdfDocument.Open(AccessKit.Build(21, page))), AccessibilityRule.Bookmarks, AccessibilityStatus.Failed);

        var outlined = AccessKit.Build(21, page, catalog: "/Outlines 48 0 R", more: pdf =>
        {
            pdf.Obj(48, "<</Type /Outlines /First 49 0 R /Last 49 0 R /Count 1>>");
            pdf.Obj(49, "<</Title (Start) /Parent 48 0 R /Dest [3 0 R /Fit]>>");
        });
        AssertRule(AccessibilityChecker.Check(PdfDocument.Open(outlined)), AccessibilityRule.Bookmarks, AccessibilityStatus.Passed);
    }

    [Theory]
    [InlineData(PdfPermissions.All, AccessibilityStatus.Passed)]
    [InlineData(PdfPermissions.Print | PdfPermissions.Copy, AccessibilityStatus.Failed)]
    public void SecurityMustAllowAccessibilityExtraction(PdfPermissions permissions, AccessibilityStatus expected)
    {
        using var plain = PdfDocument.Open(AccessKit.Report(1));
        var id = new byte[16];
        var security = PdfSecurity.Create("", "owner", permissions, PdfCryptStrength.Aes128, id);
        using var document = PdfDocument.Open(plain.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id)));

        AssertRule(AccessibilityChecker.Check(document), AccessibilityRule.Security, expected);
    }

    [Fact]
    public void ImageOnlyPagesAreNamed()
    {
        var bytes = AccessKit.Build(2, i => i == 1 ? "q 600 0 0 700 0 0 cm /Im1 Do Q" : AccessKit.Text(72, 700, "Some text."));
        var item = AccessibilityChecker.Check(PdfDocument.Open(bytes))[AccessibilityRule.Searchable];

        Assert.Equal(AccessibilityStatus.Failed, item.Status);
        Assert.Equal(1, Assert.Single(item.Where).PageIndex);
    }

    [Fact]
    public void AFontThatGivesNoTextIsFound()
    {
        var bytes = AccessKit.Build(1, _ => "BT /F3 12 Tf 72 700 Td (ABC) Tj ET", fontEntries: "/F3 8 0 R", more: pdf =>
            pdf.Obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Odd /FirstChar 65 /LastChar 67 /Widths [500 500 500] /Encoding <</Type /Encoding /Differences [65 /g1 /g2 /g3]>>>>"));
        var item = AccessibilityChecker.Check(PdfDocument.Open(bytes))[AccessibilityRule.Encoding];

        Assert.Equal(AccessibilityStatus.Failed, item.Status);
        Assert.Contains("Fonts that give no text: 1", item.Message);
    }

    [Fact]
    public void ContentOutsideTheTagsIsFound()
    {
        var item = Check(content: TaggedFile.Content + AccessKit.Text(72, 500, "Loose words"))[AccessibilityRule.TaggedContent];
        Assert.Equal(AccessibilityStatus.Failed, item.Status);

        var unknown = Check(content: TaggedFile.Content + "/P <</MCID 9>> BDC " + AccessKit.Text(72, 500, "Unlisted") + " EMC")[AccessibilityRule.TaggedContent];
        Assert.Equal(AccessibilityStatus.Failed, unknown.Status);

        var artifact = Check(content: TaggedFile.Content + "/Artifact BMC 0 0 10 10 re f EMC")[AccessibilityRule.TaggedContent];
        Assert.Equal(AccessibilityStatus.Passed, artifact.Status);

        var rule = Check(content: TaggedFile.Content + "0 0 10 10 re f")[AccessibilityRule.TaggedContent];
        Assert.Equal(AccessibilityStatus.Failed, rule.Status);
    }

    [Fact]
    public void FiguresNeedAltTextAndSayWhere()
    {
        var report = Check(o => o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2>>");
        var item = report[AccessibilityRule.FigureAlt];

        Assert.Equal(AccessibilityStatus.Failed, item.Status);
        var place = Assert.Single(item.Where);
        Assert.Equal((0, 12), (place.PageIndex, place.Element!.Number));
        Assert.Contains("page 1", item.Message);
        AssertRule(Check(o => o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2 /ActualText (x)>>"), AccessibilityRule.FigureAlt, AccessibilityStatus.Passed);
    }

    [Fact]
    public void HeadingsMustStartAtOneAndNotSkip()
    {
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /H3 /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.HeadingOrder, AccessibilityStatus.Failed);
        AssertRule(Check(o => o[10] = "<</Type /StructElem /S /H2 /P 9 0 R /Pg 3 0 R /K 0>>"), AccessibilityRule.HeadingOrder, AccessibilityStatus.Failed);
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /H /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.HeadingOrder, AccessibilityStatus.Failed);
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /H2 /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.HeadingOrder, AccessibilityStatus.Passed);
        AssertRule(Check(o => o[10] = "<</Type /StructElem /S /Heading /P 9 0 R /Pg 3 0 R /K 0>>"), AccessibilityRule.HeadingOrder, AccessibilityStatus.Passed);
    }

    [Fact]
    public void CustomTypesMustMapToStandardOnes()
    {
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /Weird /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.RoleMap, AccessibilityStatus.Failed);
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /Unmapped /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.RoleMap, AccessibilityStatus.Failed);
        AssertRule(Check(o => o[11] = "<</Type /StructElem /S /Heading /P 9 0 R /Pg 3 0 R /K 1>>"), AccessibilityRule.RoleMap, AccessibilityStatus.Passed);
    }

    private static void WithBlock(SortedDictionary<int, string> o, string kind, string[] kids, string[] objects)
    {
        o[9] = $"<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 14 0 R]>>";
        o[14] = $"<</Type /StructElem /S /{kind} /P 9 0 R /Pg 3 0 R /K [{string.Join(" ", kids)}]>>";
        for (int i = 0; i < objects.Length; i++) o[20 + i] = objects[i];
    }

    [Fact]
    public void ListsNeedItemsLabelsAndBodiesInPlace()
    {
        string Elem(string type, string parent, string kids = "") => $"<</Type /StructElem /S /{type} /P {parent} 0 R /Pg 3 0 R {kids}>>";

        AssertRule(Check(o => WithBlock(o, "L", ["20 0 R"], [Elem("P", "14")])), AccessibilityRule.ListStructure, AccessibilityStatus.Failed);
        AssertRule(Check(o => WithBlock(o, "L", ["20 0 R"], [Elem("LI", "14", "/K [21 0 R]"), Elem("P", "20")])), AccessibilityRule.ListStructure, AccessibilityStatus.Failed);
        AssertRule(Check(o => WithBlock(o, "L", ["20 0 R"], [Elem("LI", "14", "/K [21 0 R 22 0 R]"), Elem("Lbl", "20"), Elem("LBody", "20")])), AccessibilityRule.ListStructure, AccessibilityStatus.Passed);
        AssertRule(Check(o => WithBlock(o, "LBody", ["20 0 R"], [Elem("P", "14")])), AccessibilityRule.ListStructure, AccessibilityStatus.Failed);
    }

    [Fact]
    public void TablesNeedRowsOfCellsOfOneWidthAndHeaders()
    {
        string Elem(string type, string parent, string kids = "") => $"<</Type /StructElem /S /{type} /P {parent} 0 R /Pg 3 0 R {kids}>>";
        string[] regular =
        [
            Elem("TR", "14", "/K [22 0 R 23 0 R]"), Elem("TR", "14", "/K [24 0 R 25 0 R]"),
            Elem("TH", "20"), Elem("TH", "20"), Elem("TD", "21"), Elem("TD", "21"),
        ];
        var good = Check(o => WithBlock(o, "Table", ["20 0 R", "21 0 R"], regular));
        AssertRule(good, AccessibilityRule.TableStructure, AccessibilityStatus.Passed);
        AssertRule(good, AccessibilityRule.TableHeaders, AccessibilityStatus.Passed);

        string[] noHeaders = [.. regular];
        noHeaders[2] = Elem("TD", "20");
        noHeaders[3] = Elem("TD", "20");
        var plain = Check(o => WithBlock(o, "Table", ["20 0 R", "21 0 R"], noHeaders));
        AssertRule(plain, AccessibilityRule.TableStructure, AccessibilityStatus.Passed);
        AssertRule(plain, AccessibilityRule.TableHeaders, AccessibilityStatus.Failed);

        string[] ragged = [.. regular];
        ragged[1] = Elem("TR", "14", "/K [24 0 R]");
        AssertRule(Check(o => WithBlock(o, "Table", ["20 0 R", "21 0 R"], ragged)), AccessibilityRule.TableStructure, AccessibilityStatus.Failed);

        string[] spanned = [.. ragged];
        spanned[4] = "<</Type /StructElem /S /TD /P 21 0 R /Pg 3 0 R /A <</O /Table /ColSpan 2>>>>";
        AssertRule(Check(o => WithBlock(o, "Table", ["20 0 R", "21 0 R"], spanned)), AccessibilityRule.TableStructure, AccessibilityStatus.Passed);

        AssertRule(Check(o => WithBlock(o, "Table", ["20 0 R"], [Elem("P", "14")])), AccessibilityRule.TableStructure, AccessibilityStatus.Failed);
        string[] sections = [Elem("TBody", "14", "/K [22 0 R]"), Elem("THead", "14", "/K [23 0 R]"), Elem("TR", "20", "/K [24 0 R]"), Elem("TR", "21", "/K [25 0 R]"), Elem("TH", "22"), Elem("TD", "23")];
        AssertRule(Check(o => WithBlock(o, "Table", ["20 0 R", "21 0 R"], sections)), AccessibilityRule.TableStructure, AccessibilityStatus.Passed);
    }

    [Fact]
    public void LinksMustBeTaggedAndHaveText()
    {
        PdfDocument Open(string linkElement, string annotation = "/Border [0 0 0]") =>
            PdfDocument.Open(AccessKit.Build(1, _ => TaggedFile.Content, "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en)", "/StructParents 0 /Tabs /S /Annots [20 0 R]", pdf =>
            {
                foreach (var (n, body) in TaggedFile.Objects().Where(e => e.Key != 9)) pdf.Obj(n, body);
                pdf.Obj(9, $"<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R{(linkElement.Length > 0 ? " 21 0 R" : "")}]>>");
                pdf.Obj(20, $"<</Type /Annot /Subtype /Link /Rect [0 0 9 9] {annotation} /StructParent 1>>");
                if (linkElement.Length > 0) pdf.Obj(21, linkElement);
            }));

        AssertRule(AccessibilityChecker.Check(Open("")), AccessibilityRule.Links, AccessibilityStatus.Failed);
        AssertRule(AccessibilityChecker.Check(Open("<</S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>")), AccessibilityRule.Links, AccessibilityStatus.Failed);
        AssertRule(AccessibilityChecker.Check(Open("<</S /Link /P 9 0 R /Pg 3 0 R /Alt (Site) /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>")), AccessibilityRule.Links, AccessibilityStatus.Passed);
        AssertRule(AccessibilityChecker.Check(Open("<</S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>", "/Contents (Site)")), AccessibilityRule.Links, AccessibilityStatus.Passed);
    }

    [Fact]
    public void FormFieldsNeedNamesTooltipsAndTags()
    {
        PdfDocument Open(string field) => PdfDocument.Open(AccessKit.Build(1, _ => TaggedFile.Content,
            "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en) /AcroForm <</Fields [20 0 R]>>", "/StructParents 0 /Tabs /S /Annots [20 0 R]", pdf =>
            {
                foreach (var (n, body) in TaggedFile.Objects().Where(e => e.Key != 9)) pdf.Obj(n, body);
                pdf.Obj(9, "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 21 0 R]>>");
                pdf.Obj(20, $"<</Type /Annot /Subtype /Widget /FT /Tx /Rect [100 100 200 120] /P 3 0 R {field}>>");
                pdf.Obj(21, "<</S /Form /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>");
            }));

        var good = AccessibilityChecker.Check(Open("/T (name) /TU (Your name)"));
        AssertRule(good, AccessibilityRule.FormNames, AccessibilityStatus.Passed);
        AssertRule(good, AccessibilityRule.FormTagged, AccessibilityStatus.Passed);
        var item = AccessibilityChecker.Check(Open("/T (name)"))[AccessibilityRule.FormNames];
        Assert.Equal(AccessibilityStatus.Failed, item.Status);
        Assert.Equal(20, item.Where[0].Element!.Number);
    }

    [Fact]
    public void AFormFieldOutsideTheTagsIsFound()
    {
        var bytes = AccessKit.Build(1, _ => TaggedFile.Content,
            "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en) /AcroForm <</Fields [20 0 R]>>", "/StructParents 0 /Tabs /S /Annots [20 0 R]", pdf =>
            {
                foreach (var (n, body) in TaggedFile.Objects()) pdf.Obj(n, body);
                pdf.Obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /TU (A) /Rect [100 100 200 120] /P 3 0 R>>");
            });

        AssertRule(AccessibilityChecker.Check(PdfDocument.Open(bytes)), AccessibilityRule.FormTagged, AccessibilityStatus.Failed);
    }

    [Fact]
    public void AutoTaggedFilesPassOnceTheyAreDescribed()
    {
        using var document = PdfDocument.Open(AccessKit.Report(3));
        var result = AutoTagger.Tag(document, new AutoTagOptions("en-US"));
        var first = AccessibilityChecker.Check(document);
        AssertRule(first, AccessibilityRule.Tagged, AccessibilityStatus.Passed);
        AssertRule(first, AccessibilityRule.TaggedContent, AccessibilityStatus.Passed);
        AssertRule(first, AccessibilityRule.Language, AccessibilityStatus.Passed);
        AssertRule(first, AccessibilityRule.FigureAlt, AccessibilityStatus.Failed);
        AssertRule(first, AccessibilityRule.Title, AccessibilityStatus.Failed);

        var tree = StructureTree.Read(document)!;
        foreach (var figure in result.FiguresWithoutAlt)
        {
            tree.Elements.First(e => e.Reference?.Number == figure.Reference.Number).Alt = "A grey square";
        }
        tree.Write(document);
        AccessibilityChecker.Fix(document, AccessibilityFix.SetTitle, "Quarterly report");

        using var again = AccessKit.Reopen(document, rewrite: true);
        var report = AccessibilityChecker.Check(again);
        foreach (var item in report.Items.Where(i => i.Rule != AccessibilityRule.Contrast))
        {
            Assert.True(item.Status == AccessibilityStatus.Passed, $"{item.Rule}: {item.Status} - {item.Message}");
        }
        Assert.Equal(1, report.NeedsPerson);
    }

    [Fact]
    public void LocationsAreCappedButCounted()
    {
        var bytes = AccessKit.Build(60, _ => "q 600 0 0 700 0 0 cm /Im1 Do Q");
        var item = AccessibilityChecker.Check(PdfDocument.Open(bytes))[AccessibilityRule.Searchable];

        Assert.Equal(50, item.Where.Count);
        Assert.Contains("60", item.Message);
    }

    [Fact]
    public void CancellationStopsTheCheck()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => AccessibilityChecker.Check(PdfDocument.Open(AccessKit.Report(2)), source.Token));
    }
}
