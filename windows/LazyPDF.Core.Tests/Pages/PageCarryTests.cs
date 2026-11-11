using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageCarryTests
{
    // Six pages (objects 4 to 9). Bookmarks: Part A (Ch1, Ch2), Part B (Ch3, Ch4 by action), Ch5 by name, Ch6.
    // Labels are i, ii, iii and then 1, 2, 3. Names: three and five.
    private static PdfDocument Fixture(string? title = null, bool brokenFile = false) => PdfDocument.Open(PageTestFiles.Make(6,
        "/Outlines 16 0 R /PageLabels <</Nums [0 <</S /r>> 3 <</S /D>>]>> /Lang (en-CA) /Metadata 25 0 R " +
        "/Names <</Dests <</Names [(five) [8 0 R /Fit] (three) [6 0 R /Fit]]>> /EmbeddedFiles <</Names [(note.txt) 27 0 R]>>>>",
        add: pdf => pdf
            .Obj(16, "<</Type /Outlines /First 17 0 R /Last 24 0 R /Count 8>>")
            .Obj(17, "<</Title (Part A) /Parent 16 0 R /Next 20 0 R /First 18 0 R /Last 19 0 R /Count 2>>")
            .Obj(18, "<</Title (Ch1) /Parent 17 0 R /Next 19 0 R /Dest [4 0 R /Fit]>>")
            .Obj(19, "<</Title (Ch2) /Parent 17 0 R /Prev 18 0 R /Dest [5 0 R /Fit]>>")
            .Obj(20, "<</Title (Part B) /Parent 16 0 R /Prev 17 0 R /Next 23 0 R /First 21 0 R /Last 22 0 R /Count 2>>")
            .Obj(21, "<</Title (Ch3) /Parent 20 0 R /Next 22 0 R /Dest [6 0 R /Fit]>>")
            .Obj(22, "<</Title (Ch4) /Parent 20 0 R /Prev 21 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>")
            .Obj(23, "<</Title (Ch5) /Parent 16 0 R /Prev 20 0 R /Next 24 0 R /Dest (five)>>")
            .Obj(24, "<</Title (Ch6) /Parent 16 0 R /Prev 23 0 R /Dest [9 0 R /Fit]>>")
            .Stream(25, "/Type /Metadata /Subtype /XML", "<x:xmpmeta>fixture</x:xmpmeta>")
            .Stream(26, brokenFile ? "/Type /EmbeddedFile /Filter /FlateDecode" : "/Type /EmbeddedFile", "hello")
            .Obj(27, "<</Type /Filespec /F (note.txt) /UF (note.txt) /EF <</F 26 0 R>>>>")
            .Obj(28, $"<</Title ({title})>>"),
        trailerExtra: title is null ? "" : "/Info 28 0 R"));

    private static string Dump(IEnumerable<OutlineItem> items) =>
        string.Join(",", items.Select(i => i.Title + (i.Destination is { } d ? ">" + d.PageIndex : "") + (i.Children.Count > 0 ? "[" + Dump(i.Children) + "]" : "")));

    private static string Bookmarks(PdfDocument document) => Dump(Outline.Read(PdfDocument.Open(document.SaveRewrite())).Items);

    private static string Names(PdfDocument document) =>
        string.Join(",", PdfDestinations.Named(PdfDocument.Open(document.SaveRewrite())).Select(n => n.Key + ">" + n.Value.PageIndex));

    private static string Files(PdfDocument document)
    {
        var again = PdfDocument.Open(document.SaveRewrite());
        return string.Join(",", PdfAttachments.List(again).Select(a => a.Name + "=" + Encoding.Latin1.GetString(PdfAttachments.Extract(again, a))));
    }

    private static bool Holds(byte[] file, string marker)
    {
        if (Encoding.Latin1.GetString(file).Contains(marker)) return true;
        var document = PdfDocument.Open(file);
        return document.ObjectNumbers.Any(n => document.Get(n) switch
        {
            PdfStream stream => Encoding.Latin1.GetString(document.Data(stream)).Contains(marker),
            { } other => other.ToString()!.Contains(marker),
            _ => false,
        });
    }

    [Fact]
    public void ExtractKeepsWhatBelongsToThePagesTaken()
    {
        var part = PageAssembly.Extract(Fixture("Source"), [2, 3]);
        Assert.Equal("Part B[Ch3>0,Ch4>1]", Bookmarks(part));
        Assert.Equal(["iii", "1"], PdfPageLabels.Labels(PdfDocument.Open(part.SaveRewrite())));
        Assert.Equal("three>0", Names(part));
        Assert.Equal("note.txt=hello", Files(part));
        var again = PdfDocument.Open(part.SaveRewrite());
        Assert.Equal("en-CA", Encoding.Latin1.GetString(((PdfString)again.Catalog["Lang"]!).Bytes));
        Assert.Contains("fixture", Encoding.Latin1.GetString(again.Data(again.Stream(again.Catalog, "Metadata")!)));
    }

    [Fact]
    public void NothingThatReachesAPageLeftOutIsWritten()
    {
        byte[] bytes = PageAssembly.Extract(Fixture(), [2, 3]).SaveRewrite();
        foreach (string marker in new[] { "Page 1", "Page 2", "Ch1", "Ch2", "Part A", "Ch5", "Ch6", "five" }) Assert.False(Holds(bytes, marker), marker);
    }

    [Fact]
    public void AnItemWithAnActionOrANameIsCarriedExplicit()
    {
        var part = PageAssembly.Extract(Fixture(), [3, 4]);
        Assert.Equal("Part B[Ch4>0],Ch5>1", Bookmarks(part));
        Assert.Equal("five>1", Names(part));
        var items = Outline.Read(PdfDocument.Open(part.SaveRewrite())).Items;
        Assert.All(items.SelectMany(i => i.Children.Append(i)), i => Assert.Null(i.Destination?.Name));
    }

    [Fact]
    public void ALabelRangeWithAGapKeepsCounting()
    {
        var part = PageAssembly.Extract(Fixture(), [0, 2, 5, 3]);
        Assert.Equal(["i", "iii", "3", "1"], PdfPageLabels.Labels(PdfDocument.Open(part.SaveRewrite())));
    }

    [Fact]
    public void AFileWithoutLabelsOrBookmarksGetsNone()
    {
        var again = PdfDocument.Open(PageAssembly.Extract(PageTestFiles.Open(3), [0, 1]).SaveRewrite());
        Assert.Empty(PdfPageLabels.Read(again));
        Assert.Empty(Outline.Read(again).Items);
        Assert.Null(again.Catalog["Lang"]);
        Assert.Null(again.Catalog["Names"]);
    }

    [Fact]
    public void TheXmpOnlyComesWithTheInfo()
    {
        var again = PdfDocument.Open(PageAssembly.Extract(Fixture(), [0]).SaveRewrite());
        Assert.Null(again.Catalog["Metadata"]);
        Assert.NotNull(again.Catalog["Lang"]);
    }

    private const string ClaimingPacket =
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
        "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\" " +
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" pdfaid:part=\"2\"><pdfaid:conformance>B</pdfaid:conformance><pdfuaid:part>1</pdfuaid:part>" +
        "<dc:format>application/pdf</dc:format></rdf:Description></rdf:RDF></x:xmpmeta>";

    private static PdfDocument Claiming() => PdfDocument.Open(PageTestFiles.Make(2, "/Metadata 25 0 R",
        add: pdf => pdf.Stream(25, "/Type /Metadata /Subtype /XML", ClaimingPacket).Obj(28, "<</Title (T)>>"),
        trailerExtra: "/Info 28 0 R"));

    private static string XmpOf(PdfDocument document)
    {
        var again = PdfDocument.Open(document.SaveRewrite());
        return Encoding.UTF8.GetString(again.Data(again.Stream(again.Catalog, "Metadata")!));
    }

    [Fact]
    public void ExtractedXmpKeepsItsPropertiesButNotThePdfAndPdfUaClaims()
    {
        string xmp = XmpOf(PageAssembly.Extract(Claiming(), [0]));
        Assert.DoesNotContain("pdfaid:", xmp.Replace("xmlns:pdfaid", ""));
        Assert.DoesNotContain("pdfuaid:", xmp.Replace("xmlns:pdfuaid", ""));
        Assert.Contains("application/pdf", xmp);
    }

    [Fact]
    public void MergedXmpHasNoPdfAClaim()
    {
        string xmp = XmpOf(PageAssembly.Merge([new MergeSource(Claiming()), new MergeSource(Claiming(), [1])]));
        Assert.DoesNotContain("pdfaid:", xmp.Replace("xmlns:pdfaid", ""));
        Assert.Contains("application/pdf", xmp);
    }

    [Fact]
    public void MergeMakesOneItemForEachSourceWithBookmarks()
    {
        var merged = PageAssembly.Merge([new MergeSource(Fixture("First")), new MergeSource(Fixture("Second"), [2, 3]), new MergeSource(PageTestFiles.Open(1))]);
        Assert.Equal("First[Part A[Ch1>0,Ch2>1],Part B[Ch3>2,Ch4>3],Ch5>4,Ch6>5],Second[Part B[Ch3>6,Ch4>7]]", Bookmarks(merged));
        Assert.Empty(PdfPageLabels.Read(PdfDocument.Open(merged.SaveRewrite())));
    }

    [Fact]
    public void MergeTitlesComeFromTheCallerWhenTheFileHasNone()
    {
        var merged = PageAssembly.Merge([new MergeSource(Fixture(), [0]), new MergeSource(Fixture(), [1]), new MergeSource(PageTestFiles.Open(1))], titles: ["One", "Two", "Three"]);
        Assert.Equal("One[Part A[Ch1>0]],Two[Part A[Ch2>1]]", Bookmarks(merged));
    }

    [Fact]
    public void MergeCarriesEveryAttachmentUnderAFreshNameAndTheFirstSourcesInfoAndXmp()
    {
        var merged = PageAssembly.Merge([new MergeSource(Fixture("First")), new MergeSource(Fixture("Second"), [5])]);
        Assert.Equal("note (2).txt=hello,note.txt=hello", Files(merged));
        Assert.Equal("five>4,three>2", Names(merged));
        var again = PdfDocument.Open(merged.SaveRewrite());
        Assert.NotNull(again.Catalog["Metadata"]);
        Assert.Equal("First", Encoding.Latin1.GetString(((PdfString)again.Info!["Title"]!).Bytes));
    }

    [Fact]
    public void ADocumentListedTwiceCarriesItsAttachmentsOnce()
    {
        var same = Fixture("Same");
        var merged = PageAssembly.Merge([new MergeSource(same, [0]), new MergeSource(same, [5]), new MergeSource(Fixture("Other"), [1])]);
        Assert.Equal("note (2).txt=hello,note.txt=hello", Files(merged));
    }

    [Fact]
    public void AnAttachmentThatDoesNotDecodeIsSkippedAndCounted()
    {
        var part = PageAssembly.Extract(Fixture(brokenFile: true), [2, 3]);
        Assert.Equal("", Files(part));
        Assert.Equal(1, part.SkippedAttachments);
        var merged = PageAssembly.Merge([new MergeSource(Fixture(brokenFile: true)), new MergeSource(Fixture(), [5])]);
        Assert.Equal("note.txt=hello", Files(merged));
        Assert.Equal(1, merged.SkippedAttachments);
        Assert.Equal([1, 0], PageAssembly.SplitAt(Fixture(brokenFile: true), [3]).Select(p => p.SkippedAttachments));
    }

    [Fact]
    public void EachPartOfASplitCarriesItsOwn()
    {
        var parts = PageAssembly.SplitAt(Fixture(), [3]);
        Assert.Equal("Part A[Ch1>0,Ch2>1],Part B[Ch3>2]", Bookmarks(parts[0]));
        Assert.Equal("Part B[Ch4>0],Ch5>1,Ch6>2", Bookmarks(parts[1]));
        Assert.Equal(["i", "ii", "iii"], PdfPageLabels.Labels(PdfDocument.Open(parts[0].SaveRewrite())));
        Assert.Equal(["1", "2", "3"], PdfPageLabels.Labels(PdfDocument.Open(parts[1].SaveRewrite())));
        Assert.Equal("three>2", Names(parts[0]));
        Assert.Equal("five>1", Names(parts[1]));
        Assert.Equal(["note.txt=hello", ""], parts.Select(Files));
    }

    [Fact]
    public void AttachmentsGoIntoTheFirstPartOfASplitBySizeOnly()
    {
        var document = Fixture();
        long one = PageAssembly.Extract(document, [0]).SaveRewrite().Length;
        var parts = PageAssembly.SplitBySize(document, one + 200);
        Assert.True(parts.Count > 1);
        Assert.Equal("note.txt=hello", Files(parts[0]));
        Assert.All(parts.Skip(1), p => Assert.Equal("", Files(p)));
        var byRanges = PageAssembly.SplitByRanges(document, [[0, 1], [2], [3]]);
        Assert.Equal(["note.txt=hello", "", ""], byRanges.Select(Files));
    }
}
