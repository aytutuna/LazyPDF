using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PptxWriterTests
{
    private static readonly XNamespace A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private static readonly XNamespace P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/package/2006/relationships";

    private static readonly ExportDocument Model = ExportLayout.Analyze(ExportKit.Report());
    private static readonly byte[] Package = PptxWriter.Make(Model);

    private static XDocument Part(string name) => XDocument.Parse(ExportKit.Unzip(Package, name));

    [Fact]
    public void ASlideForEachPageSizedAsThePage()
    {
        var presentation = Part("ppt/presentation.xml");
        Assert.Equal(3, presentation.Descendants(P + "sldId").Count());
        var size = presentation.Descendants(P + "sldSz").Single();
        Assert.Equal((612 * 12700L, 792 * 12700L), (long.Parse((string)size.Attribute("cx")!), long.Parse((string)size.Attribute("cy")!)));
    }

    [Fact]
    public void EveryRelationshipTargetsAPartAndEveryPartIsWellFormed()
    {
        var entries = ExportKit.Entries(Package);
        Assert.All(entries.Where(e => e.EndsWith(".xml") || e.EndsWith(".rels")), e => Part(e));
        foreach (string rels in entries.Where(e => e.EndsWith(".rels")))
        {
            string folder = rels.Contains("_rels/") ? rels[..rels.IndexOf("_rels/", StringComparison.Ordinal)] : "";
            foreach (var rel in Part(rels).Descendants(Rel + "Relationship"))
            {
                string target = (string)rel.Attribute("Target")!;
                string full = new Uri(new Uri("file:///" + folder), target).AbsolutePath.TrimStart('/');
                Assert.Contains(Uri.UnescapeDataString(full), entries);
            }
        }
        var types = Part("[Content_Types].xml").ToString();
        for (int i = 1; i <= 3; i++) Assert.Contains($"/ppt/slides/slide{i}.xml", types);
    }

    [Fact]
    public void EveryLineIsATextBoxAtItsPlace()
    {
        var slide = Part("ppt/slides/slide1.xml");
        var boxes = slide.Descendants(P + "sp").ToList();
        Assert.Equal(Model.Pages[0].Lines.Count, boxes.Count);
        var heading = boxes.Single(b => b.Value == "Annual Report");
        var offset = heading.Descendants(A + "off").Single();
        var line = Model.Pages[0].Lines.Single(l => l.Text == "Annual Report");
        Assert.Equal((long)Math.Round(line.Bounds.X * 12700), long.Parse((string)offset.Attribute("x")!));
        Assert.Equal((long)Math.Round(line.Bounds.Y * 12700), long.Parse((string)offset.Attribute("y")!));
        var run = heading.Descendants(A + "rPr").Single();
        Assert.Equal("1", (string)run.Attribute("b")!);
        Assert.Equal("2400", (string)run.Attribute("sz")!);
    }

    [Fact]
    public void ThePictureIsPlacedAndSharedBetweenSlides()
    {
        var picture = Part("ppt/slides/slide1.xml").Descendants(P + "pic").Single();
        var ext = picture.Descendants(A + "ext").Single();
        Assert.Equal((96 * 12700L, 72 * 12700L), (long.Parse((string)ext.Attribute("cx")!), long.Parse((string)ext.Attribute("cy")!)));
        string id = (string)picture.Descendants(A + "blip").Single().Attribute(R + "embed")!;
        var target = Part("ppt/slides/_rels/slide1.xml.rels").Descendants(Rel + "Relationship").Single(r => (string)r.Attribute("Id")! == id);
        Assert.Equal("../media/image1.jpg", (string)target.Attribute("Target")!);
        Assert.Single(ExportKit.Entries(Package), e => e.StartsWith("ppt/media/"));
    }

    [Fact]
    public void ABiggerPageIsScaledIntoTheSlide()
    {
        var small = new ExportPage(0, 100, 100, [], [new ExportTextLine(new DisplayRect(10, 10, 50, 10), [new ExportRun("A", false, false, 10)])], []);
        var big = new ExportPage(1, 200, 200, [], [new ExportTextLine(new DisplayRect(20, 20, 100, 20), [new ExportRun("B", false, true, 20)])], []);
        var package = PptxWriter.Make(new ExportDocument(null, [small, big], 10));
        var run = XDocument.Parse(ExportKit.Unzip(package, "ppt/slides/slide2.xml")).Descendants(A + "rPr").Single();
        // The slide takes the first page's size and the bigger page shrinks into it.
        Assert.Equal("1", (string)run.Attribute("i")!);
        Assert.True(int.Parse((string)run.Attribute("sz")!) < 2000);
    }

    [Fact]
    public void TurkishTextIsKept()
    {
        var line = new ExportTextLine(new DisplayRect(10, 10, 200, 14), [new ExportRun("İstanbul ğüşıöç", false, false, 12)]);
        var package = PptxWriter.Make(new ExportDocument(null, [new ExportPage(0, 612, 792, [], [line], [])], 12));
        Assert.Equal("İstanbul ğüşıöç", XDocument.Parse(ExportKit.Unzip(package, "ppt/slides/slide1.xml")).Descendants(A + "t").Single().Value);
    }

    [Fact]
    public void ADocumentWithoutPagesHasNoSlides()
    {
        var package = PptxWriter.Make(new ExportDocument(null, [], 11));
        Assert.DoesNotContain("sldIdLst", ExportKit.Unzip(package, "ppt/presentation.xml"));
    }
}
