using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PptxTests
{
    private static LayoutResult Layout(byte[] package, PptxLimits? limits = null)
    {
        var fonts = OfficeLayoutSpec.Fonts();
        return PptxLayout.Run(PptxReader.Read(package, limits), new LayoutFonts(fonts));
    }

    private static PdfReadProblem? Problem(Action work)
    {
        try
        {
            work();
            return null;
        }
        catch (PdfReadException e)
        {
            return e.Problem;
        }
    }

    private static string Box(string name, string text, int x = 0, int y = 0) =>
        $"<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"{name}\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"3048000\" cy=\"457200\"/></a:xfrm><a:prstGeom prst=\"rect\"/></p:spPr>" +
        $"<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:txBody></p:sp>";

    private static byte[] Slides(int count, string shapes) =>
        PptxSpec.One(string.Concat(Enumerable.Range(1, count).Select(n => $"@slide{n}\n<p:cSld><p:spTree>{shapes}</p:spTree></p:cSld>\n")));

    [Fact]
    public void SlideLayoutGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in PptxSpec.Read(Golden.Input("office-pptx", "pptx-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(PptxSpec.Dump(Layout(package)));
        }
        Golden.Check("office-pptx", "pptx-output.txt", output.ToString());
    }

    [Fact]
    public void ShapeLayoutGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in PptxSpec.Read(Golden.Input("office-pptx", "shapes-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(PptxSpec.Dump(Layout(package)));
        }
        Golden.Check("office-pptx", "shapes-output.txt", output.ToString());
    }

    [Fact]
    public void OnePagePerSlideAtTheSlideSizeWithoutTheHiddenOnes()
    {
        var package = PptxSpec.One("@presentation\n<p:sldSz cx=\"12192000\" cy=\"6858000\"/>\n@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2 show=0\n<p:cSld><p:spTree/></p:cSld>\n@slide3\n<p:cSld><p:spTree/></p:cSld>\n");
        var layout = Layout(package);
        Assert.Equal(2, layout.Pages.Count);
        Assert.All(layout.Pages, p => Assert.Equal((960.0, 540.0), (p.Width, p.Height)));
        Assert.Equal([new SkippedFeature("hidden-slide", 1)], layout.Skipped);
    }

    [Fact]
    public void ThemeColorsFollowThePublishedOfficeShades()
    {
        var layout = Layout(PptxSpec.One(
            "@slide1\n<p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val=\"accent1\"><a:lumMod val=\"75000\"/></a:schemeClr></a:solidFill></p:bgPr></p:bg><p:spTree>" +
            "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"B\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"/><a:solidFill><a:schemeClr val=\"bg1\"><a:lumMod val=\"95000\"/></a:schemeClr></a:solidFill></p:spPr></p:sp>" +
            "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"C\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"/><a:solidFill><a:schemeClr val=\"accent1\"><a:lumMod val=\"60000\"/><a:lumOff val=\"40000\"/></a:schemeClr></a:solidFill></p:spPr></p:sp>" +
            "</p:spTree></p:cSld>\n"));
        var colors = layout.Pages[0].Boxes.OfType<PlacedRect>().Select(r => r.Color).ToList();
        Assert.Equal([0xF2F2F2, 0x95B3D7], colors.Skip(1));
        // Office rounds lightness to a 240 step scale, so its darker shade (366092) is a few steps off the exact one.
        Assert.All(new[] { 16, 8, 0 }, shift => Assert.InRange((colors[0] >> shift & 0xFF) - (0x366092 >> shift & 0xFF), -4, 4));
    }

    [Fact]
    public void ThePlaceholderTakesPositionAndStyleFromTheLayoutAndMaster()
    {
        var parts = new List<(string, byte[])>(PptxSpec.Read(Golden.Input("office-pptx", "pptx-input.txt")));
        var layout = Layout(parts.First(p => p.Item1.StartsWith("placeholders", StringComparison.Ordinal)).Item2);
        var title = layout.Pages[0].Boxes.OfType<PlacedText>().First(t => t.Text == "A title");
        Assert.Equal(44, title.Size);
        Assert.Equal("Cambria", title.Family);
        Assert.Equal(0x1F497D, title.Color);
        Assert.True(title.Style.HasFlag(FontStyles.Bold));
        var first = layout.Pages[0].Boxes.OfType<PlacedText>().First(t => t.Text == "First point");
        Assert.Equal(28, first.Size);
        Assert.True(first.X > 36 + 14.4 - 0.01);
    }

    [Fact]
    public void AnEmptyPlaceholderDrawsNothing()
    {
        var package = PptxSpec.One("@slide1\n<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp></p:spTree></p:cSld>\n");
        var layout = Layout(package);
        Assert.Empty(layout.Pages[0].Boxes);
        Assert.Empty(layout.Skipped);
    }

    [Fact]
    public void ThePowerPointConverterWritesAPageForEverySlide()
    {
        var package = PptxSpec.One("@slide1\n<p:cSld><p:spTree>" + Box("A", "First slide") + "</p:spTree></p:cSld>\n@slide2\n<p:cSld><p:spTree>" + Box("B", "Second slide") + "</p:spTree></p:cSld>\n");
        var pdf = OfficeConverter.FromPowerPoint(package, OfficeLayoutSpec.Fonts());
        Assert.Equal(2, pdf.Pages);
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Contains("First slide", read.GetPage(1).Text);
        Assert.Contains("Second slide", read.GetPage(2).Text);
        Assert.Equal(720, read.GetPage(1).Width, 0.01);
    }

    [Fact]
    public void AnOldPowerPointFileIsRefusedWithAHint()
    {
        byte[] ole = [0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0];
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => PptxReader.Read(ole)));
    }

    [Fact]
    public void APackageThatIsNotAPresentationIsRefused()
    {
        var workbook = XlsxSpec.Package(new Dictionary<string, StringBuilder> { ["workbook"] = new("<sheets/>") });
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => PptxReader.Read(workbook)));
    }

    [Fact]
    public void AllSlidesHiddenLeavesNothingToShow()
    {
        var package = PptxSpec.One("@slide1 show=0\n<p:cSld><p:spTree/></p:cSld>\n");
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(package)));
    }

    [Fact]
    public void MoreSlidesThanTheLimitAreRefused()
    {
        var package = Slides(3, "");
        Assert.Equal(3, Layout(package, new PptxLimits(MaxSlides: 3)).Pages.Count);
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(package, new PptxLimits(MaxSlides: 2))));
    }

    [Fact]
    public void ShapesPastTheLimitAreCountedNotRead()
    {
        var package = Slides(1, Box("A", "one") + Box("B", "two") + Box("C", "three"));
        var layout = Layout(package, new PptxLimits(MaxShapes: 2));
        Assert.Equal(2, layout.Pages[0].Boxes.OfType<PlacedText>().Count());
        Assert.Equal([new SkippedFeature("slide-shape", 1)], layout.Skipped);
    }

    [Fact]
    public void ParagraphsAndTextPastTheLimitAreCutAndNoted()
    {
        string body = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"3048000\" cy=\"457200\"/></a:xfrm><a:prstGeom prst=\"rect\"/></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>{0}</p:txBody></p:sp>";
        var paragraphs = Slides(1, string.Format(body, "<a:p><a:r><a:t>a</a:t></a:r></a:p><a:p><a:r><a:t>b</a:t></a:r></a:p><a:p><a:r><a:t>c</a:t></a:r></a:p>"));
        var cutParagraphs = Layout(paragraphs, new PptxLimits(MaxParagraphs: 2));
        Assert.Equal(["a", "b"], cutParagraphs.Pages[0].Boxes.OfType<PlacedText>().Select(t => t.Text));
        Assert.Equal([new SkippedFeature("slide-text-cut", 1)], cutParagraphs.Skipped);

        var text = Slides(1, string.Format(body, "<a:p><a:r><a:t>ab\U0001F600cd</a:t></a:r></a:p>"));
        var cut = Layout(text, new PptxLimits(MaxTextLength: 3));
        Assert.Equal("ab", cut.Pages[0].Boxes.OfType<PlacedText>().Single().Text);
        Assert.Equal([new SkippedFeature("slide-text-cut", 1)], cut.Skipped);
    }

    [Fact]
    public void TooMuchTextInAllIsRefused()
    {
        var package = Slides(2, Box("A", "abcd"));
        Layout(package, new PptxLimits(MaxTotalText: 8));
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(package, new PptxLimits(MaxTotalText: 7))));
    }

    [Fact]
    public void SharedMasterShapesCountTowardTheDrawnLimitOnEverySlide()
    {
        var master = "@master1\n<p:cSld><p:spTree>" + Box("M", "mark") + Box("N", "mark") + "</p:spTree></p:cSld>\n";
        var package = PptxSpec.One(master + "@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2\n<p:cSld><p:spTree/></p:cSld>\n");
        Assert.Equal(2, Layout(package, new PptxLimits(MaxDrawnShapes: 4)).Pages.Count);
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(package, new PptxLimits(MaxDrawnShapes: 3))));
    }

    [Fact]
    public void SharedMasterTextCountsTowardTheTotalOnEverySlide()
    {
        var master = "@master1\n<p:cSld><p:spTree>" + Box("M", "mark") + Box("N", "mark") + "</p:spTree></p:cSld>\n";
        var package = PptxSpec.One(master + "@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2\n<p:cSld><p:spTree/></p:cSld>\n");
        Layout(package, new PptxLimits(MaxTotalText: 24));
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(package, new PptxLimits(MaxTotalText: 23))));
    }

    [Fact]
    public void ASlideWhoseLayoutRelationshipPointsAtAMasterIsStillDrawn()
    {
        var package = PptxSpec.One("@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2 layout=/../../slideMasters/slideMaster1\n<p:cSld><p:spTree>" + Box("A", "kept") + "</p:spTree></p:cSld>\n");
        var pages = Layout(package).Pages;
        Assert.Equal(2, pages.Count);
        Assert.Contains(pages[1].Boxes, b => b is PlacedText { Text: "kept" });
    }

    [Fact]
    public void ASlideWhoseLayoutIsMissingIsStillDrawn()
    {
        var package = PptxSpec.One("@slide1 layout=9\n<p:cSld><p:spTree>" + Box("A", "kept") + "</p:spTree></p:cSld>\n");
        Assert.Contains(Layout(package).Pages[0].Boxes, b => b is PlacedText { Text: "kept" });
    }

    [Fact]
    public void ThePageBoxesOfAFarOutShapeStayFinite()
    {
        var package = Slides(1, Box("A", "far", x: int.MaxValue, y: int.MinValue));
        var layout = Layout(package);
        Assert.All(layout.Pages[0].Boxes.OfType<PlacedText>(), t => Assert.True(double.IsFinite(t.X) && double.IsFinite(t.Baseline)));
    }

    private const string Jpeg = "ffd8ffc0000b080003000401011100ffd9";
    private const string Image = "<Relationship Id=\"rIdP\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/pic.jpg\"/>";

    private static string Pic(int x) =>
        $"<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"P\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdP\"/></p:blipFill><p:spPr><a:xfrm><a:off x=\"{x}\" y=\"0\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm></p:spPr></p:pic>";

    private static byte[] WithPictures(string shapes) =>
        PptxSpec.One($"@slide1\n<p:cSld><p:spTree>{shapes}</p:spTree></p:cSld>\n@rels slide1\n{Image}\n@bytes ppt/media/pic.jpg\n{Jpeg}\n");

    private static string Group(int depth, string inside) =>
        depth == 0 ? inside : Group(depth - 1, $"<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"{depth}\" name=\"G\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"635000\" cy=\"635000\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"635000\" cy=\"635000\"/></a:xfrm></p:grpSpPr>{inside}</p:grpSp>");

    [Fact]
    public void ShapeContentGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in PptxSpec.Read(Golden.Input("office-pptx", "shapes-input.txt")))
        {
            var contents = new List<byte[]>();
            OfficePdfWriter.Create(Layout(package), OfficeLayoutSpec.Fonts(), contents: contents);
            output.Append("> ").Append(name).Append('\n');
            foreach (var page in contents)
            {
                output.Append("page\n");
                foreach (string line in Encoding.Latin1.GetString(page).TrimEnd('\n').Split('\n')) output.Append("| ").Append(line).Append('\n');
            }
        }
        Golden.Check("office-pptx", "shapes-content.txt", output.ToString());
    }

    [Fact]
    public void AJpegOnASlideIsPlacedAtItsFrameAndRotated()
    {
        var pdf = OfficeConverter.FromPowerPoint(WithPictures(Pic(127000)), OfficeLayoutSpec.Fonts());
        Assert.Empty(pdf.Skipped);
        using var read = PigDocument.Open(pdf.Bytes);
        var image = Assert.Single(read.GetPage(1).GetImages());
        Assert.Equal(10, image.BoundingBox.Left, 0.01);
        Assert.Equal(100, image.BoundingBox.Width, 0.01);
        Assert.Equal(50, image.BoundingBox.Height, 0.01);

        var contents = new List<byte[]>();
        OfficePdfWriter.Create(Layout(WithPictures(Pic(0).Replace("<a:xfrm>", "<a:xfrm rot=\"5400000\">"))), OfficeLayoutSpec.Fonts(), contents: contents);
        Assert.Contains("0 -1 1 0 ", Encoding.Latin1.GetString(contents[0]));
    }

    [Fact]
    public void OtherPicturesNeedTheCodec()
    {
        var package = PptxSpec.One($"@slide1\n<p:cSld><p:spTree>{Pic(0)}</p:spTree></p:cSld>\n@rels slide1\n{Image}\n@bytes ppt/media/pic.jpg\n50020280808080\n");
        var with = OfficeConverter.FromPowerPoint(package, OfficeLayoutSpec.Fonts(), new ExportFakeCodec());
        Assert.Empty(with.Skipped);
        using (var read = PigDocument.Open(with.Bytes)) Assert.Single(read.GetPage(1).GetImages());
        var without = OfficeConverter.FromPowerPoint(package, OfficeLayoutSpec.Fonts());
        Assert.Equal([new SkippedFeature("picture", 1)], without.Skipped);
    }

    [Fact]
    public void PicturesPastTheLimitAreCounted()
    {
        var package = WithPictures(Pic(0) + Pic(127000) + Pic(254000));
        var layout = Layout(package, new PptxLimits(MaxPictures: 2));
        Assert.Equal(2, layout.Pages[0].Boxes.OfType<PlacedImage>().Count());
        Assert.Equal([new SkippedFeature("picture", 1)], layout.Skipped);
    }

    [Fact]
    public void GroupsDeeperThanTheLimitAreCountedWithTheirContent()
    {
        string leaf = Box("Leaf", "deep");
        var within = Layout(Slides(1, Group(2, leaf)), new PptxLimits(MaxGroupDepth: 2));
        Assert.Single(within.Pages[0].Boxes.OfType<PlacedText>());
        var beyond = Layout(Slides(1, Group(3, leaf) + Box("Kept", "kept")), new PptxLimits(MaxGroupDepth: 2));
        Assert.Equal(["kept"], beyond.Pages[0].Boxes.OfType<PlacedText>().Select(t => t.Text));
        Assert.Equal([new SkippedFeature("slide-shape", 1)], beyond.Skipped);
    }

    [Fact]
    public void ShapesInsideGroupsCountTowardTheShapeLimit()
    {
        var layout = Layout(Slides(1, Group(1, Box("A", "one") + Box("B", "two") + Box("C", "three"))), new PptxLimits(MaxShapes: 3));
        Assert.Equal(["one", "two"], layout.Pages[0].Boxes.OfType<PlacedText>().Select(t => t.Text));
        Assert.Equal([new SkippedFeature("slide-shape", 1)], layout.Skipped);
    }

    private static string Table(int rows, int columns)
    {
        string cell = "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>x</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>";
        string grid = string.Concat(Enumerable.Repeat("<a:gridCol w=\"635000\"/>", columns));
        string row = "<a:tr h=\"254000\">" + string.Concat(Enumerable.Repeat(cell, columns)) + "</a:tr>";
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1\" cy=\"1\"/></p:xfrm>" +
            $"<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblGrid>{grid}</a:tblGrid>{string.Concat(Enumerable.Repeat(row, rows))}</a:tbl></a:graphicData></a:graphic></p:graphicFrame>";
    }

    [Fact]
    public void ATableWithinTheLimitsIsDrawnAndOneBeyondThemIsCounted()
    {
        var limits = new PptxLimits(MaxTableRows: 3, MaxTableColumns: 2);
        var fits = Layout(Slides(1, Table(3, 2)), limits);
        Assert.Equal(6, fits.Pages[0].Boxes.OfType<PlacedText>().Count());
        Assert.Empty(fits.Skipped);

        var tooManyRows = Layout(Slides(1, Table(4, 2) + Box("A", "kept")), limits);
        Assert.Equal(["kept"], tooManyRows.Pages[0].Boxes.OfType<PlacedText>().Select(t => t.Text));
        Assert.Equal([new SkippedFeature("slide-shape", 1)], tooManyRows.Skipped);
        Assert.Equal([new SkippedFeature("slide-shape", 1)], Layout(Slides(1, Table(2, 3) + Box("A", "kept")), limits).Skipped);
    }

    [Fact]
    public void ATableCountsItsTextTowardTheTotal()
    {
        Layout(Slides(1, Table(2, 2)), new PptxLimits(MaxTotalText: 4));
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(Slides(1, Table(2, 2)), new PptxLimits(MaxTotalText: 3))));
    }

    [Fact]
    public void ShapesAndTablesAreWrittenToThePdf()
    {
        string shapes = Table(2, 2) +
            "<p:sp><p:nvSpPr><p:cNvPr id=\"5\" name=\"S\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm rot=\"2700000\"><a:off x=\"2540000\" y=\"2540000\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm><a:prstGeom prst=\"homePlate\"/>" +
            "<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill><a:ln w=\"12700\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:prstDash val=\"dash\"/></a:ln></p:spPr></p:sp>";
        var pdf = OfficeConverter.FromPowerPoint(Slides(1, shapes), OfficeLayoutSpec.Fonts());
        Assert.Empty(pdf.Skipped);
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Equal(4, read.GetPage(1).Letters.Count(l => l.Value == "x"));
        Assert.Single(read.GetPage(1).Paths, p => p.IsFilled && p.IsStroked);
    }
}
