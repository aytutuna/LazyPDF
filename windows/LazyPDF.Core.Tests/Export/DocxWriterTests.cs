using System.IO.Compression;
using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class DocxWriterTests
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/package/2006/relationships";
    private static readonly byte[] Package = DocxWriter.Make(ExportLayout.Analyze(ExportKit.Report()));

    private static XDocument Part(byte[] package, string name) => XDocument.Parse(ExportKit.Unzip(package, name));

    [Fact]
    public void EveryPartIsWellFormedAndEveryCrcIsRight()
    {
        using var zip = new ZipArchive(new MemoryStream(Package), ZipArchiveMode.Read);
        foreach (var entry in zip.Entries)
        {
            using var stream = entry.Open();
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            Assert.Equal(entry.Crc32, ExportZip.Crc32(copy.ToArray()));
            if (entry.FullName.EndsWith(".xml") || entry.FullName.EndsWith(".rels")) XDocument.Parse(System.Text.Encoding.UTF8.GetString(copy.ToArray()));
        }
        Assert.Contains("word/document.xml", zip.Entries.Select(e => e.FullName));
    }

    [Fact]
    public void RelationshipsPointAtPartsThatExist()
    {
        var entries = ExportKit.Entries(Package);
        var rels = Part(Package, "word/_rels/document.xml.rels").Root!.Elements(Rel + "Relationship").ToList();
        Assert.All(rels, r => Assert.Contains("word/" + (string)r.Attribute("Target")!, entries));
        var used = Part(Package, "word/document.xml").Descendants().Attributes(R + "embed").Select(a => a.Value).ToList();
        Assert.NotEmpty(used);
        Assert.All(used, id => Assert.Contains(rels, r => (string)r.Attribute("Id")! == id));
        var types = Part(Package, "[Content_Types].xml").ToString();
        Assert.Contains("image/jpeg", types);
        Assert.Contains("wordprocessingml.document.main+xml", types);
    }

    [Fact]
    public void HeadingsParagraphsRunsAndPageBreaksAreWritten()
    {
        var body = Part(Package, "word/document.xml").Root!.Element(W + "body")!;
        var paragraphs = body.Elements(W + "p").ToList();
        var heading = paragraphs.First(p => p.Value == "Annual Report");
        Assert.Equal("Heading1", (string)heading.Descendants(W + "pStyle").Single().Attribute(W + "val")!);
        var second = paragraphs.First(p => p.Value == "Second paragraph with important words.");
        var runs = second.Elements(W + "r").ToList();
        Assert.Single(runs, r => r.Descendants(W + "b").Any());
        Assert.Single(runs, r => r.Descendants(W + "i").Any());
        Assert.Equal(2, body.Descendants(W + "pageBreakBefore").Count());
    }

    [Fact]
    public void ListsUseNumberingAndTheTableHasItsGrid()
    {
        var body = Part(Package, "word/document.xml").Root!.Element(W + "body")!;
        var numIds = body.Descendants(W + "numId").Select(n => (string)n.Attribute(W + "val")!).Distinct().Order().ToList();
        Assert.Equal(6, numIds.Count);
        var numbering = Part(Package, "word/numbering.xml").Root!;
        Assert.Equal(6, numbering.Elements(W + "num").Count());
        Assert.Equal(3, numbering.Elements(W + "num").Count(n => n.Descendants(W + "startOverride").Any()));

        var table = body.Elements(W + "tbl").First();
        Assert.Equal(2, table.Elements(W + "tr").Count());
        Assert.Equal(2, table.Element(W + "tblGrid")!.Elements(W + "gridCol").Count());
        Assert.Equal(["Item", "Price"], table.Elements(W + "tr").First().Elements(W + "tc").Select(c => c.Value));
        Assert.Equal("1,250.50", table.Elements(W + "tr").Last().Elements(W + "tc").Last().Value);
    }

    [Fact]
    public void ThePictureIsInlineAndItsMediaIsTheJpegAsStored()
    {
        var document = Part(Package, "word/document.xml");
        var extent = document.Descendants().First(e => e.Name.LocalName == "extent");
        Assert.Equal((96 * 12700L, 72 * 12700L), (long.Parse((string)extent.Attribute("cx")!), long.Parse((string)extent.Attribute("cy")!)));
        var media = ExportKit.Entries(Package).Where(e => e.StartsWith("word/media/")).ToList();
        Assert.Single(media);
        using var zip = new ZipArchive(new MemoryStream(Package), ZipArchiveMode.Read);
        using var stored = new MemoryStream();
        zip.GetEntry(media[0])!.Open().CopyTo(stored);
        Assert.Equal(ExportKit.Jpeg, stored.ToArray());
    }

    [Fact]
    public void PaperAndMarginsFollowThePage()
    {
        var section = Part(Package, "word/document.xml").Descendants(W + "sectPr").Single();
        var size = section.Element(W + "pgSz")!;
        Assert.Equal(("12240", "15840"), (size.Attribute(W + "w")!.Value, size.Attribute(W + "h")!.Value));
        var margin = section.Element(W + "pgMar")!;
        Assert.Equal("1440", margin.Attribute(W + "left")!.Value);
    }

    [Fact]
    public void XmlSpecialsAreEscapedAndImpossibleCharactersLeftOut()
    {
        var document = One(new ExportParagraph(new DisplayRect(72, 72, 100, 12), [new ExportRun("a < b & c > \"d\" \u0001x\ud800y\tz", false, false, 11)]));
        var parts = Part(DocxWriter.Make(document), "word/document.xml").Descendants(W + "t").Select(t => t.Value).ToList();
        Assert.Equal(["a < b & c > \"d\" xy", "z"], parts);
        Assert.Single(Part(DocxWriter.Make(document), "word/document.xml").Descendants(W + "tab"));
    }

    [Fact]
    public void TurkishTextSurvivesFromPdfThroughDocxXml()
    {
        const string turkish = "Çağrı Öztürk'ün şirketi İstanbul'da, ığdır ve Şanlıurfa'ya gitti. ĞÜŞİÖÇ ğüşıöç";
        var made = PdfFromText.Create(turkish, new ExportArialSource());
        using var reopened = PdfDocument.Open(made.Bytes);
        var package = DocxWriter.Make(ExportLayout.Analyze(reopened));
        var text = string.Concat(Part(package, "word/document.xml").Descendants(W + "t").Select(t => t.Value));
        Assert.Equal(turkish, text.Trim());
    }

    [Fact]
    public void AnEmptyDocumentIsStillAValidPackage()
    {
        var package = DocxWriter.Make(new ExportDocument(null, [], 11));
        var body = Part(package, "word/document.xml").Root!.Element(W + "body")!;
        Assert.NotNull(body.Element(W + "p"));
        Assert.NotNull(body.Element(W + "sectPr"));
    }

    [Fact]
    public void TheTitleGoesToTheCoreProperties()
    {
        var package = DocxWriter.Make(new ExportDocument("Rapor & özet", [], 11));
        Assert.Contains("Rapor &amp; özet", ExportKit.Unzip(package, "docProps/core.xml"));
        Assert.Contains("core-properties", ExportKit.Unzip(package, "_rels/.rels"));
    }

    [Fact]
    public void NestedListsKeepTheirLevels()
    {
        var document = One(
            new ExportParagraph(new DisplayRect(72, 72, 100, 12), [new ExportRun("top", false, false, 11)], 0, new ExportListItem(1, false, 0, 0)),
            new ExportParagraph(new DisplayRect(90, 90, 100, 12), [new ExportRun("inner", false, false, 11)], 0, new ExportListItem(1, false, 1, 0)));
        var levels = Part(DocxWriter.Make(document), "word/document.xml").Descendants(W + "ilvl").Select(e => e.Attribute(W + "val")!.Value);
        Assert.Equal(["0", "1"], levels);
    }

    private static ExportDocument One(params ExportBlock[] blocks) =>
        new("t", [new ExportPage(0, 612, 792, blocks, [], [])], 11);
}
