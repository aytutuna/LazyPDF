using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfALevelATests
{
    private static readonly PdfALevel[] Levels = [PdfALevel.A1a, PdfALevel.A2a, PdfALevel.A3a];

    [Fact]
    public void LevelsKnowTheirPartAndConformance()
    {
        Assert.Equal([1, 2, 3], Levels.Select(l => l.Part()));
        Assert.All(Levels, l => Assert.Equal("A", l.Conformance()));
        Assert.Equal(["PDF/A-1a", "PDF/A-2a", "PDF/A-3a"], Levels.Select(l => l.Name()));
        Assert.All(Levels, l => Assert.True(l.NeedsTags() && l.NeedsUnicode()));
        Assert.False(PdfALevel.A2u.NeedsTags());
    }

    [Fact]
    public void ATaggedFilePassesEveryLevelA()
    {
        foreach (var level in Levels) StandardsKit.AssertClean(StandardsKit.Tagged(level), level);
    }

    [Fact]
    public void AnUntaggedFileFailsTheStructureRules()
    {
        foreach (var level in Levels)
        {
            var issues = StandardsKit.Check(StandardsKit.Compliant(level), level).Issues;
            Assert.Contains(issues, i => i.Message == PdfAText.NoMarkInfo);
            Assert.Contains(issues, i => i.Message == PdfAText.NoStructTree);
        }
        Assert.Contains("6.8.3.1", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1a), PdfALevel.A1a));
        Assert.Contains("6.7.2", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A2a), PdfALevel.A2a));
    }

    [Fact]
    public void LevelBAndUFilesAreNotHeldToTheStructureRules()
    {
        StandardsKit.AssertClean(StandardsKit.Compliant(PdfALevel.A2b), PdfALevel.A2b);
        StandardsKit.AssertClean(StandardsKit.Compliant(PdfALevel.A2u), PdfALevel.A2u);
    }

    [Fact]
    public void AMissingOrFalseMarkInfoIsReported()
    {
        var missing = StandardsKit.Check(StandardsKit.Tagged(PdfALevel.A2a, marked: ""), PdfALevel.A2a).Issues;
        Assert.Equal(PdfAText.NoMarkInfo, Assert.Single(missing).Message);
        var no = StandardsKit.Tagged(PdfALevel.A2a, marked: "/MarkInfo <</Marked false>>");
        Assert.Contains(StandardsKit.Check(no, PdfALevel.A2a).Issues, i => i.Message == PdfAText.NoMarkInfo);
    }

    [Fact]
    public void AMissingLanguageIsReportedUnlessTheTopElementsHaveOne()
    {
        var issues = StandardsKit.Check(StandardsKit.Tagged(PdfALevel.A3a, lang: ""), PdfALevel.A3a).Issues;
        Assert.Equal(PdfAText.NoLanguage, Assert.Single(issues).Message);

        var onElement = StandardsKit.Edited(StandardsKit.Tagged(PdfALevel.A3a, lang: ""), d =>
        {
            var root = d.Dict(d.Catalog, "StructTreeRoot")!;
            ((PdfDictionary)d.Resolve(root["K"])!)["Lang"] = PdfText.ToObject("fr");
        });
        StandardsKit.AssertClean(onElement, PdfALevel.A3a);
    }

    [Fact]
    public void ContentOutsideTheTreeIsReportedPerPage()
    {
        var file = StandardsKit.Tagged(PdfALevel.A2a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC 1 0 0 rg 130 20 50 50 re f");
        var issue = Assert.Single(StandardsKit.Check(file, PdfALevel.A2a).Issues);
        Assert.Equal("6.7.3.1", issue.Clause);
        Assert.Equal(PdfAText.PageName(1), issue.Where);
    }

    [Fact]
    public void AnArtifactMayStandOutsideTheTree()
    {
        var file = StandardsKit.Tagged(PdfALevel.A2a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC /Artifact BMC 1 0 0 rg 130 20 50 50 re f EMC");
        StandardsKit.AssertClean(file, PdfALevel.A2a);
    }

    [Fact]
    public void ASequenceTheTreeDoesNotHoldIsReported()
    {
        var file = StandardsKit.Tagged(PdfALevel.A1a, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC /Span <</MCID 5>> BDC 1 0 0 rg 130 20 50 50 re f EMC");
        Assert.Contains("6.8.3.3", StandardsKit.Clauses(file, PdfALevel.A1a));
    }

    [Fact]
    public void ContentTheParentTreeCannotLeadBackIsReported()
    {
        foreach (var level in new[] { PdfALevel.A1a, PdfALevel.A2a, PdfALevel.A3a })
        {
            var none = StandardsKit.Check(StandardsKit.Tagged(level, structParents: ""), level).Issues;
            Assert.Contains(none, i => i.Message == PdfAText.NoStructParents && i.Where == "Page 1");
            var wrong = StandardsKit.Check(StandardsKit.Tagged(level, parentTree: "[0 [10 0 R]]"), level).Issues;
            Assert.Contains(wrong, i => i.Message == PdfAText.ParentTreeMismatch);
        }
    }

    [Fact]
    public void ACustomTypeNeedsARoleMapToAStandardOne()
    {
        var bad = StandardsKit.Tagged(PdfALevel.A2a, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart");
        var issue = Assert.Single(StandardsKit.Check(bad, PdfALevel.A2a).Issues);
        Assert.Equal(PdfAText.NonStandardType("Chart"), issue.Message);
        StandardsKit.AssertClean(StandardsKit.Tagged(PdfALevel.A2a, roleMap: "/RoleMap <</Chart /Figure>>", figureType: "Chart"), PdfALevel.A2a);
    }

    [Fact]
    public void ARoleMapCycleIsNotStandard()
    {
        var file = StandardsKit.Tagged(PdfALevel.A2a, roleMap: "/RoleMap <</A /B /B /A>>", figureType: "A");
        Assert.Contains(StandardsKit.Check(file, PdfALevel.A2a).Issues, i => i.Message == PdfAText.NonStandardType("A"));
    }

    [Fact]
    public void TypesOfPdf15AreStandardFromPart2Only()
    {
        Assert.Contains("6.8.3.4", StandardsKit.Clauses(StandardsKit.Tagged(PdfALevel.A1a, figureType: "Annot"), PdfALevel.A1a));
        Assert.DoesNotContain("6.7.3.2", StandardsKit.Clauses(StandardsKit.Tagged(PdfALevel.A2a, figureType: "Annot"), PdfALevel.A2a));
    }

    [Fact]
    public void AFigureOrFormulaNeedsAlternateText()
    {
        var issue = Assert.Single(StandardsKit.Check(StandardsKit.Tagged(PdfALevel.A2a, alt: ""), PdfALevel.A2a).Issues);
        Assert.Equal(PdfAText.NoAlternateText("Figure"), issue.Message);
        StandardsKit.AssertClean(StandardsKit.Tagged(PdfALevel.A2a, alt: "/ActualText (square)"), PdfALevel.A2a);
        var formula = StandardsKit.Tagged(PdfALevel.A2a, figureType: "Formula", alt: "");
        Assert.Contains(StandardsKit.Check(formula, PdfALevel.A2a).Issues, i => i.Message == PdfAText.NoAlternateText("Formula"));
    }

    [Fact]
    public void LevelANeedsConformanceAInTheMetadata()
    {
        var asB = StandardsKit.Tagged(PdfALevel.A2b);
        Assert.Contains("6.6.4", StandardsKit.Clauses(asB, PdfALevel.A2a));
    }

    [Fact]
    public void ConversionKeepsATaggedFileAndDeclaresTheLevel()
    {
        foreach (var level in Levels)
        {
            var result = new PdfAConverter().Convert(StandardsKit.Tagged(level), level, StandardsKit.Date);
            Assert.True(result.IsClean, string.Join("\n", result.Remaining.Select(i => $"{i.Clause} {i.Message}")));
            Assert.Contains("<pdfaid:conformance>A</pdfaid:conformance>", StandardsKit.Latin(result.Bytes!));
        }
    }

    [Fact]
    public void ConversionMarksATreeThatLacksMarkInfo()
    {
        var result = new PdfAConverter().Convert(StandardsKit.Tagged(PdfALevel.A2a, marked: ""), PdfALevel.A2a, StandardsKit.Date);
        Assert.True(result.IsClean);
        Assert.Contains(PdfAText.Marked, result.Changes);
    }

    [Fact]
    public void ConversionRefusesAnUntaggedFileWithoutALanguage()
    {
        foreach (var level in Levels)
        {
            var result = new PdfAConverter().Convert(StandardsKit.Compliant(level), level, StandardsKit.Date);
            Assert.Null(result.Bytes);
            Assert.StartsWith(level.Name(), result.Refusal);
            Assert.Contains(PdfAText.NoStructTree, result.Refusal);
            Assert.EndsWith(PdfAText.SetLanguageToTag, result.Refusal);
        }
    }

    [Fact]
    public void ConversionRefusesTaggingThatStillBreaksTheRules()
    {
        var result = new PdfAConverter().Convert(StandardsKit.Tagged(PdfALevel.A2a, alt: ""), PdfALevel.A2a, StandardsKit.Date);
        Assert.Null(result.Bytes);
        Assert.Contains(PdfAText.NoAlternateText("Figure"), result.Refusal);
        var chart = new PdfAConverter().Convert(StandardsKit.Tagged(PdfALevel.A2a, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart"), PdfALevel.A2a, StandardsKit.Date);
        Assert.Contains(PdfAText.NonStandardType("Chart"), chart.Refusal);
    }

    [Fact]
    public void ConversionStillRefusesWhenOtherIssuesFillTheReport()
    {
        const int pages = 1001;
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(' ', Enumerable.Range(0, pages).Select(i => $"{10 + i} 0 R"))}] /Count {pages} /MediaBox [0 0 200 300]>>");
        pdf.Stream(3, "", "1 0 0 rg 10 10 50 50 re f");
        for (int i = 0; i < pages; i++) pdf.Obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents 3 0 R>>");
        var result = new PdfAConverter().Convert(pdf.Finish("/Root 1 0 R"), PdfALevel.A2a, StandardsKit.Date);
        Assert.Null(result.Bytes);
        Assert.EndsWith(PdfAText.SetLanguageToTag, result.Refusal);
    }

    [Fact]
    public void ConversionTagsAnUntaggedFileThatNamesItsLanguage()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        var result = new PdfAConverter().Convert(pdf.Finish("/Root 1 0 R"), PdfALevel.A2a, StandardsKit.Date);
        Assert.Null(result.Refusal);
        Assert.Contains(PdfAText.Tagged(1), result.Changes);
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.True(document.IsTagged);
        Assert.DoesNotContain(result.Remaining, i => i.Message == PdfAText.NoStructTree);
    }
}
