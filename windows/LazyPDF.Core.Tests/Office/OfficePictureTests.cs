using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class OfficePictureTests
{
    // A JPEG header of 4 by 3 pixels, and a picture file only ExportFakeCodec reads.
    private const string Jpeg = "ffd8ffc0000b080003000401011100ffd9";
    private const string Png = "50020280808080";
    private const string ImageRelationship = "<Relationship Id=\"rIdI1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/a.bin\"/>";

    private static string Drawing(string frame = "inline", long cx = 1270000, long cy = 635000) =>
        $"<w:r><w:drawing><wp:{frame}><wp:extent cx=\"{cx}\" cy=\"{cy}\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:blipFill><a:blip r:embed=\"rIdI1\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:{frame}></w:drawing></w:r>";

    private static byte[] Docx(string body, string picture, Dictionary<string, StringBuilder>? more = null)
    {
        var parts = new Dictionary<string, StringBuilder>
        {
            ["document"] = new(body),
            ["relationships"] = new(ImageRelationship),
            ["bytes word/media/a.bin"] = new(picture),
        };
        if (more is not null) foreach (var (key, value) in more) parts[key] = value;
        return DocxSpec.Package(parts);
    }

    [Fact]
    public void AJpegIsPlacedAtItsExtent()
    {
        var pdf = OfficeConverter.FromWord(Docx($"<w:p>{Drawing()}</w:p>", Jpeg), OfficeLayoutSpec.Fonts());
        Assert.Empty(pdf.Skipped);
        using var read = PigDocument.Open(pdf.Bytes);
        var image = Assert.Single(read.GetPage(1).GetImages());
        Assert.Equal(100, image.BoundingBox.Width, 0.01);
        Assert.Equal(50, image.BoundingBox.Height, 0.01);
    }

    [Fact]
    public void OtherPicturesNeedTheCodec()
    {
        string body = $"<w:p>{Drawing()}</w:p>";
        var codec = new ExportFakeCodec();
        var withCodec = OfficeConverter.FromWord(Docx(body, Png), OfficeLayoutSpec.Fonts(), codec);
        Assert.Empty(withCodec.Skipped);
        using (var read = PigDocument.Open(withCodec.Bytes)) Assert.Single(read.GetPage(1).GetImages());

        var without = OfficeConverter.FromWord(Docx(body, Png), OfficeLayoutSpec.Fonts());
        Assert.Equal([new SkippedFeature("picture", 1)], without.Skipped);
        using (var read = PigDocument.Open(without.Bytes)) Assert.Empty(read.GetPage(1).GetImages());
    }

    [Fact]
    public void ABrokenPictureIsCountedAndTheRestIsStillWritten()
    {
        var pdf = OfficeConverter.FromWord(Docx($"<w:p><w:r><w:t>text</w:t></w:r>{Drawing()}{Drawing()}</w:p>", "0102030405"), OfficeLayoutSpec.Fonts(), new ExportFakeCodec());
        Assert.Equal([new SkippedFeature("picture", 2)], pdf.Skipped);
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Contains("text", read.GetPage(1).Text);
    }

    [Fact]
    public void AFloatingPictureIsPlacedInLineAndReported()
    {
        var pdf = OfficeConverter.FromWord(Docx($"<w:p>{Drawing("anchor")}</w:p>", Jpeg), OfficeLayoutSpec.Fonts());
        Assert.Equal([new SkippedFeature("floating-picture", 1)], pdf.Skipped);
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Single(read.GetPage(1).GetImages());
    }

    [Fact]
    public void ARepeatedPictureIsOneImageObject()
    {
        var once = OfficeConverter.FromWord(Docx($"<w:p>{Drawing()}</w:p>", Png), OfficeLayoutSpec.Fonts(), new ExportFakeCodec());
        var thrice = OfficeConverter.FromWord(Docx($"<w:p>{Drawing()}{Drawing()}{Drawing()}</w:p>", Png), OfficeLayoutSpec.Fonts(), new ExportFakeCodec());
        using var read = PigDocument.Open(thrice.Bytes);
        Assert.Equal(3, read.GetPage(1).GetImages().Count());
        Assert.True(thrice.Bytes.Length - once.Bytes.Length < 200, $"{thrice.Bytes.Length} against {once.Bytes.Length}");
    }

    [Fact]
    public void APictureLargerThanThePageShrinksToIt()
    {
        var pdf = OfficeConverter.FromWord(Docx($"<w:p>{Drawing(cx: 100_000_000, cy: 50_000_000)}</w:p>", Jpeg), OfficeLayoutSpec.Fonts());
        Assert.Equal(1, pdf.Pages);
        using var read = PigDocument.Open(pdf.Bytes);
        var image = Assert.Single(read.GetPage(1).GetImages());
        Assert.True(image.BoundingBox.Width <= 468.01, image.BoundingBox.Width.ToString());
        Assert.Equal(2, image.BoundingBox.Width / image.BoundingBox.Height, 0.01);
    }

    [Fact]
    public void OnlyTheFirst2000PicturesAreKept()
    {
        string body = string.Concat(Enumerable.Repeat($"<w:p>{Drawing()}</w:p>", 2005));
        var document = DocxReader.Read(Docx(body, Jpeg));
        var runs = document.Sections.SelectMany(s => s.Blocks).OfType<LayoutParagraph>().SelectMany(p => p.Runs);
        Assert.Equal(2000, runs.Count(r => r.Picture is not null));
        Assert.Contains(document.Skipped, s => s is { Kind: "picture", Count: 5 });
    }

    private static string Band(string root, string text) =>
        $"<w:{root} xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:{root}>";

    [Fact]
    public void FirstAndEvenPagesUseTheirOwnHeaders()
    {
        string rels = ImageRelationship +
            "<Relationship Id=\"rIdH2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header2.xml\"/>" +
            "<Relationship Id=\"rIdH3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header3.xml\"/>";
        string page = "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>";
        string body = "<w:p><w:r><w:t>one</w:t></w:r></w:p>" + page + "<w:p><w:r><w:t>two</w:t></w:r></w:p>" + page + "<w:p><w:r><w:t>three</w:t></w:r></w:p>" + page +
            "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"rIdH\"/><w:headerReference w:type=\"first\" r:id=\"rIdH2\"/><w:headerReference w:type=\"even\" r:id=\"rIdH3\"/><w:titlePg/></w:sectPr>";
        var parts = new Dictionary<string, StringBuilder>
        {
            ["document"] = new(body),
            ["relationships"] = new(rels),
            ["header"] = new("<w:p><w:r><w:t>Odd</w:t></w:r></w:p>"),
            ["part word/header2.xml"] = new(Band("hdr", "First")),
            ["part word/header3.xml"] = new(Band("hdr", "Even")),
            ["settings"] = new("<w:evenAndOddHeaders/>"),
        };
        var pdf = OfficeConverter.FromWord(DocxSpec.Package(parts), OfficeLayoutSpec.Fonts());
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Equal(4, read.NumberOfPages);
        string[] expected = ["First", "Even", "Odd", "Even"];
        for (int i = 0; i < 4; i++) Assert.StartsWith(expected[i], read.GetPage(i + 1).Text);
    }
}
