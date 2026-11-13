using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfUaCheckerTests
{
    private static void Fails(string condition, byte[] file)
    {
        var report = PdfUaKit.Check(file);
        Assert.True(report.Issues.Any(i => i.Condition == condition), $"{condition} not found in:\n{PdfUaKit.Describe(report)}");
    }

    private static void Passes(byte[] file)
    {
        var report = PdfUaKit.Check(file);
        Assert.True(report.IsValid, PdfUaKit.Describe(report));
    }

    [Fact]
    public void AGoodFilePasses() => Passes(PdfUaKit.Build());

    [Fact]
    public void IssuesCarryTheCheckpointAndTheClause()
    {
        var issue = Assert.Single(PdfUaKit.Check(PdfUaKit.Build(viewer: "")).Issues);

        Assert.Equal("07-001", issue.Condition);
        Assert.Equal("07", issue.Checkpoint);
        Assert.Equal("7.1", issue.Clause);
        Assert.False(string.IsNullOrWhiteSpace(issue.Message));
    }

    [Fact]
    public void TheCatalogMustBeMarkedAndHoldATree()
    {
        Fails("01-001", PdfUaKit.Build(markInfo: ""));
        Fails("01-007", PdfUaKit.Build(markInfo: "/MarkInfo <</Marked true /Suspects true>>"));
        Fails("01-002", PdfUaKit.Build(tree: false));
    }

    [Fact]
    public void ContentIsTaggedOrAnArtifact()
    {
        Fails("01-005", PdfUaKit.Build(content: PdfUaKit.Figure + " 1 0 0 rg 0 0 5 5 re f"));
        Passes(PdfUaKit.Build(content: PdfUaKit.Figure + " /Artifact BMC 1 0 0 rg 0 0 5 5 re f EMC"));
        Fails("01-003", PdfUaKit.Build(content: "/Figure <</MCID 0>> BDC /Artifact BMC 0 0 1 rg 20 20 100 100 re f EMC EMC"));
        Fails("01-004", PdfUaKit.Build(content: "/Artifact BMC /Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC EMC"));
    }

    [Fact]
    public void ASequenceThatTheTreeDoesNotNameIsNotTagged()
    {
        Fails("01-005", PdfUaKit.Build(content: "/Figure <</MCID 7>> BDC 0 0 1 rg 20 20 100 100 re f EMC"));
    }

    [Fact]
    public void TheRoleMapLeadsToStandardTypes()
    {
        Fails("02-001", PdfUaKit.Build(edit: o => o[10] = "<</Type /StructElem /S /Weird /P 9 0 R /K 11 0 R>>"));
        Passes(PdfUaKit.Build(edit: o =>
        {
            o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</Weird /Sect>>>>";
            o[10] = "<</Type /StructElem /S /Weird /P 9 0 R /K 11 0 R>>";
        }));

        var loop = PdfUaKit.Build(edit: o =>
        {
            o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</A /B /B /A>>>>";
            o[10] = "<</Type /StructElem /S /A /P 9 0 R /K 11 0 R>>";
        });
        Fails("02-003", loop);
        Assert.DoesNotContain("02-001", PdfUaKit.Conditions(loop));
    }

    [Fact]
    public void ManyUnmappedTypesAreReportedUpToTheLimit()
    {
        var file = PdfUaKit.Build(edit: o =>
        {
            var kids = Enumerable.Range(13, 3000).Select(n => $"{n} 0 R");
            o[10] = $"<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R {string.Join(' ', kids)}]>>";
            for (int n = 13; n < 3013; n++) o[n] = $"<</Type /StructElem /S /T{n} /P 10 0 R>>";
        });

        var report = PdfUaKit.Check(file);

        Assert.True(report.Truncated);
        Assert.Equal(1000, report.Issues.Count(i => i.Condition == "02-001"));
    }

    [Fact]
    public void CancellationStopsTheCheck()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        using var document = PdfDocument.Open(PdfUaKit.Build());
        Assert.Throws<OperationCanceledException>(() => PdfUaValidator.Validate(document, source.Token));
    }

    [Fact]
    public void AStandardTypeIsNotRemapped()
    {
        Fails("02-004", PdfUaKit.Build(edit: o => o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</P /Span>>>>"));
    }

    [Fact]
    public void TheMetadataNamesPdfUaAndHoldsATitle()
    {
        Fails("06-001", PdfUaKit.Build(xmp: ""));
        Fails("06-001", PdfUaKit.Build(xmp: "<x:xmpmeta"));
        Fails("06-002", PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false)));
        Fails("06-003", PdfUaKit.Build(xmp: PdfUaKit.Packet(title: false)));
    }

    [Fact]
    public void TheWindowShowsTheTitle()
    {
        Fails("07-001", PdfUaKit.Build(viewer: ""));
        Fails("07-001", PdfUaKit.Build(viewer: "/ViewerPreferences <</Direction /L2R>>"));
        Fails("07-002", PdfUaKit.Build(viewer: "/ViewerPreferences <</DisplayDocTitle false>>"));
    }

    [Fact]
    public void TablesAndListsNestAsTheStandardSays()
    {
        Fails("09-004", PdfUaKit.Build(edit: o =>
        {
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K 13 0 R>>";
            o[13] = "<</Type /StructElem /S /TD /P 11 0 R /Pg 3 0 R /K 0>>";
        }));
        Fails("09-004", PdfUaKit.Build(edit: o =>
        {
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K 13 0 R>>";
            o[13] = "<</Type /StructElem /S /TR /P 11 0 R /K 14 0 R>>";
            o[14] = "<</Type /StructElem /S /P /P 13 0 R /Pg 3 0 R /K 0>>";
        }));
        Fails("09-005", PdfUaKit.Build(edit: o =>
        {
            o[11] = "<</Type /StructElem /S /L /P 10 0 R /K 13 0 R>>";
            o[13] = "<</Type /StructElem /S /Lbl /P 11 0 R /Pg 3 0 R /K 0>>";
        }));
        Fails("09-005", PdfUaKit.Build(edit: o => o[11] = "<</Type /StructElem /S /LI /P 10 0 R /Pg 3 0 R /K 0>>"));
    }

    [Fact]
    public void AWellFormedTableAndListPass()
    {
        Passes(PdfUaKit.Build(edit: o =>
        {
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 18 0 R]>>";
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K [13 0 R 15 0 R]>>";
            o[13] = "<</Type /StructElem /S /TR /P 11 0 R /K 14 0 R>>";
            o[14] = "<</Type /StructElem /S /TH /P 13 0 R /Pg 3 0 R /K 0>>";
            o[15] = "<</Type /StructElem /S /TBody /P 11 0 R /K 16 0 R>>";
            o[16] = "<</Type /StructElem /S /TR /P 15 0 R /K 17 0 R>>";
            o[17] = "<</Type /StructElem /S /TD /P 16 0 R>>";
            o[18] = "<</Type /StructElem /S /L /P 10 0 R /K 19 0 R>>";
            o[19] = "<</Type /StructElem /S /LI /P 18 0 R /K [20 0 R 21 0 R]>>";
            o[20] = "<</Type /StructElem /S /Lbl /P 19 0 R>>";
            o[21] = "<</Type /StructElem /S /LBody /P 19 0 R>>";
            o[12] = "<</Nums [0 [14 0 R]]>>";
        }));
    }

    [Fact]
    public void TheLanguageCanBeTold()
    {
        var conditions = PdfUaKit.Conditions(PdfUaKit.Build(lang: ""));
        Assert.Contains("11-006", conditions);
        Assert.Contains("11-001", conditions);
        Fails("11-006", PdfUaKit.Build(lang: "/Lang (not a tag)"));
        Fails("11-007", PdfUaKit.Build(edit: o => o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R /Lang (x y)>>"));
    }

    [Fact]
    public void TopElementsWithALanguageStandInForTheCatalogs()
    {
        var conditions = PdfUaKit.Conditions(PdfUaKit.Build(lang: "", edit: o => o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R /Lang (tr)>>"));

        Assert.DoesNotContain("11-001", conditions);
        Assert.Contains("11-006", conditions);
    }

    [Theory]
    [InlineData("Figure", "13-004")]
    [InlineData("Formula", "17-002")]
    public void FiguresAndFormulasNeedAlternateText(string type, string condition)
    {
        Fails(condition, PdfUaKit.Build(edit: o => o[11] = $"<</Type /StructElem /S /{type} /P 10 0 R /Pg 3 0 R /K 0>>"));
        Fails(condition, PdfUaKit.Build(edit: o => o[11] = $"<</Type /StructElem /S /{type} /P 10 0 R /Pg 3 0 R /K 0 /Alt ( )>>"));
        Passes(PdfUaKit.Build(edit: o => o[11] = $"<</Type /StructElem /S /{type} /P 10 0 R /Pg 3 0 R /K 0 /ActualText (x)>>"));
    }

    private static byte[] WithHeadings(params string[] types) => PdfUaKit.Build(edit: o =>
    {
        o[10] = $"<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R {string.Join(" ", types.Select((_, i) => $"{20 + i} 0 R"))}]>>";
        for (int i = 0; i < types.Length; i++) o[20 + i] = $"<</Type /StructElem /S /{types[i]} /P 10 0 R>>";
    });

    [Fact]
    public void HeadingsAreInOrder()
    {
        Passes(WithHeadings("H1", "H2", "H3", "H2", "H1"));
        Fails("14-002", WithHeadings("H2"));
        Fails("14-003", WithHeadings("H1", "H3"));
        Fails("14-007", WithHeadings("H", "H1"));
        Assert.DoesNotContain("14-003", PdfUaKit.Conditions(WithHeadings("H1", "H2", "H1", "H2")));
    }

    [Fact]
    public void NotesHaveUniqueIds()
    {
        byte[] With(string second) => PdfUaKit.Build(edit: o =>
        {
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 13 0 R 14 0 R]>>";
            o[13] = "<</Type /StructElem /S /Note /P 10 0 R /ID (n1)>>";
            o[14] = $"<</Type /StructElem /S /Note /P 10 0 R {second}>>";
        });

        Passes(With("/ID (n2)"));
        Fails("19-003", With(""));
        Fails("19-004", With("/ID (n1)"));
    }

    [Fact]
    public void OptionalContentConfigurationsAreNamedAndStatic()
    {
        Fails("20-001", PdfUaKit.Build(catalog: "/OCProperties <</OCGs [] /D <</Name (View)>> /Configs [<</Order []>>]>>"));
        Fails("20-002", PdfUaKit.Build(catalog: "/OCProperties <</OCGs [] /D <</Order []>>>>"));
        Fails("20-003", PdfUaKit.Build(catalog: "/OCProperties <</OCGs [] /D <</Name (View) /AS []>>>>"));
        Passes(PdfUaKit.Build(catalog: "/OCProperties <</OCGs [] /D <</Name (View)>>>>"));
    }

    [Fact]
    public void EmbeddedFilesNameThemselvesTwice()
    {
        byte[] With(string spec) => PdfUaKit.Build(catalog: "/Names <</EmbeddedFiles <</Names [(a) 13 0 R]>>>>", extra: pdf => pdf.Obj(13, spec));

        Fails("21-001", With("<</Type /Filespec /F (a.txt)>>"));
        Passes(With("<</Type /Filespec /F (a.txt) /UF (a.txt)>>"));
    }

    [Fact]
    public void OnlyADynamicXfaFormFails()
    {
        Fails("25-001", PdfUaKit.Build(catalog: "/NeedsRendering true /AcroForm <</Fields [] /XFA []>>"));
        Passes(PdfUaKit.Build(catalog: "/AcroForm <</Fields [] /XFA []>>"));
    }

    [Theory]
    [InlineData(PdfPermissions.All, true)]
    [InlineData(PdfPermissions.Print | PdfPermissions.Copy, false)]
    public void SecurityMustAllowAccessibilityExtraction(PdfPermissions permissions, bool allowed)
    {
        using var plain = PdfDocument.Open(PdfUaKit.Build());
        var id = new byte[16];
        var security = PdfSecurity.Create("", "owner", permissions, PdfCryptStrength.Aes128, id);
        using var document = PdfDocument.Open(plain.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id)));

        Assert.Equal(allowed, !PdfUaValidator.Validate(document).Issues.Any(i => i.Condition == "26-002"));
    }

    private static byte[] WithAnnotation(string annotation, string elementType = "Link", bool tagged = true, string page = "/Tabs /S") =>
        PdfUaKit.Build(page: $"{page} /Annots [13 0 R]", edit: o =>
        {
            o[10] = $"<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R {(tagged ? "14 0 R" : "")}]>>";
            o[14] = $"<</Type /StructElem /S /{elementType} /P 10 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 13 0 R /Pg 3 0 R>>>>";
        }, extra: pdf => pdf.Obj(13, annotation));

    [Fact]
    public void AnnotationsAreTaggedUnderTheRightTypeAndDescribed()
    {
        const string link = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Contents (Home)>>";
        Passes(WithAnnotation(link));

        Fails("28-002", WithAnnotation(link, tagged: false));
        Fails("28-011", WithAnnotation(link, elementType: "Annot"));
        Fails("28-003", WithAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (Note)>>"));
        Fails("28-004", WithAnnotation("<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>"));
        Fails("28-004", WithAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10]>>", "Annot"));
        Passes(WithAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (Note)>>", "Annot"));
    }

    [Fact]
    public void TheElementsAltDescribesAnAnnotationButNotALink()
    {
        Passes(WithAnnotation("<</Type /Annot /Subtype /Stamp /Rect [0 0 10 10]>>", "Annot /Alt (Approved)"));
        Passes(WithAnnotation("<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10]>>", "Form /Alt (Name)"));
        Fails("28-004", WithAnnotation("<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>", "Link /Alt (Home)"));
        Fails("28-004", WithAnnotation("<</Type /Annot /Subtype /Stamp /Rect [0 0 10 10]>>", "Annot /Alt ( )"));
        Fails("28-005", WithAnnotation("<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10]>>", "Form /Alt ( )"));
    }

    [Fact]
    public void ATrapNetAnnotationIsNotAllowed()
    {
        Fails("28-007", WithAnnotation("<</Type /Annot /Subtype /TrapNet /Rect [0 0 10 10]>>", tagged: false));
        Passes(WithAnnotation("<</Type /Annot /Subtype /PrinterMark /Rect [0 0 10 10]>>", tagged: false));
    }

    [Fact]
    public void APopupNeedsNothing() => Passes(WithAnnotation("<</Type /Annot /Subtype /Popup /Rect [0 0 10 10]>>", tagged: false));

    [Fact]
    public void AWidgetNeedsAToolTipFromItselfOrItsField()
    {
        const string field = "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10] /TU (Name)>>";
        Passes(WithAnnotation(field, "Form"));
        Fails("28-005", WithAnnotation(field.Replace("/TU (Name)", ""), "Form"));
        Fails("28-010", WithAnnotation(field, "Annot"));

        Passes(PdfUaKit.Build(page: "/Tabs /S /Annots [13 0 R]", edit: o =>
        {
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 14 0 R]>>";
            o[14] = "<</Type /StructElem /S /Form /P 10 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 13 0 R /Pg 3 0 R>>>>";
        }, extra: pdf =>
        {
            pdf.Obj(13, "<</Type /Annot /Subtype /Widget /Parent 15 0 R /Rect [0 0 10 10]>>");
            pdf.Obj(15, "<</FT /Tx /T (a) /TU (Name) /Kids [13 0 R]>>");
        }));
    }

    [Fact]
    public void PagesWithAnnotationsFollowTheStructureForTabOrder()
    {
        const string link = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Contents (Home)>>";
        Fails("28-008", WithAnnotation(link, page: ""));
        Fails("28-009", WithAnnotation(link, page: "/Tabs /R"));
    }

    [Fact]
    public void AReferenceXObjectFails()
    {
        const string resources = "/XObject <</X1 13 0 R>>";
        Fails("30-001", PdfUaKit.Build(resources: resources, extra: pdf => pdf.Stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref <</F (x.pdf) /Page 0>>", "")));
        Passes(PdfUaKit.Build(resources: resources, extra: pdf => pdf.Stream(13, "/Type /XObject /Subtype /PS", "")));
        Passes(PdfUaKit.Build(resources: resources, extra: pdf => pdf.Stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", "")));
    }

    private static byte[] WithText(string fontObject, string text = "BT /F1 12 Tf 20 100 Td (Hello) Tj ET", Action<TestPdf>? more = null) =>
        PdfUaKit.Build(content: $"/P <</MCID 0>> BDC {text} EMC", resources: "/Font <</F1 13 0 R>>",
            edit: o => o[11] = "<</Type /StructElem /S /P /P 10 0 R /Pg 3 0 R /K 0>>",
            extra: pdf =>
            {
                pdf.Obj(13, fontObject);
                more?.Invoke(pdf);
            });

    [Fact]
    public void ShownFontsAreEmbedded()
    {
        const string plain = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";
        Fails("31-009", WithText(plain));
        Assert.DoesNotContain("31-009", PdfUaKit.Conditions(WithText(plain, "BT /F1 12 Tf 3 Tr 20 100 Td (Hello) Tj ET")));

        var embedded = WithText("<</Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Helv /Encoding /WinAnsiEncoding /FontDescriptor 14 0 R>>", more: pdf =>
        {
            pdf.Obj(14, "<</Type /FontDescriptor /FontName /ABCDEF+Helv /Flags 32 /FontFile 15 0 R>>");
            pdf.Stream(15, "", "x");
        });
        Assert.DoesNotContain("31-009", PdfUaKit.Conditions(embedded));
    }

    [Fact]
    public void ShownCharactersMapToUnicode()
    {
        Fails("31-027", WithText("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [65 /zzunknown]>>>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET"));
        Assert.DoesNotContain("31-027", PdfUaKit.Conditions(WithText("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")));
    }

    [Fact]
    public void ManyBrokenRulesStayWithinTheCap()
    {
        var report = PdfUaKit.Check(PdfUaKit.Build(markInfo: "", viewer: "", lang: "", xmp: ""));

        Assert.False(report.Truncated);
        Assert.InRange(report.Issues.Count, 4, 19);
    }
}
