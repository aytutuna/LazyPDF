using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class XfdfTests
{
    private static readonly DateTimeOffset Day = new(2026, 3, 1, 9, 0, 0, TimeSpan.Zero);

    private static PdfDocument Marked()
    {
        var document = Blank(2);
        var writer = new PdfAnnotationWriter(document);
        var page = document.Pages[0];
        var note = writer.AddNote(page, new PdfRect(50, 100, 70, 120), new AnnotationInfo("Ayşe", "şiir & <tag>", "Konu", Day), "Comment", [1, 0.5, 0]);
        PdfComments.Reply(document, note, "yanıt", "Can", Day.AddHours(1));
        writer.AddTextMarkup(page, AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(50, 700, 150, 714)), MarkupQuad.FromRect(new PdfRect(50, 680, 90, 694))], new AnnotationInfo("Ali"), new AnnotationStyle(Opacity: 0.5));
        writer.AddSquare(page, new PdfRect(200, 200, 300, 260), new AnnotationStyle([0, 0, 1], 3, [4, 2], [1, 1, 0.5]));
        writer.AddCircle(page, new PdfRect(200, 300, 300, 360), new AnnotationStyle(Cloud: 2));
        writer.AddLine(page, (10, 10), (110, 60), new AnnotationStyle(Width: 2), null, LineEnding.Circle, LineEnding.ClosedArrow);
        writer.AddPolygon(page, [(300, 400), (350, 450), (400, 400)]);
        writer.AddPolyLine(page, [(300, 500), (350, 550), (400, 500)]);
        writer.AddInk(page, [[(10, 300), (20, 320), (30, 310)], [(40, 300), (50, 320)]]);
        writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "boxed text", new FreeTextStyle("Times New Roman", 14, FontStyles.Bold, [0, 0, 1], 1),
            new AnnotationStyle([1, 0, 0], 2, Fill: [1, 1, 0.8]), new AnnotationInfo("Ali"));
        writer.AddCaret(page, new PdfRect(400, 100, 416, 116));
        writer.AddStamp(page, new PdfRect(300, 600, 500, 660), "Draft");
        return document;
    }

    // XFDF only has RGB, so a gray comes back as three equal numbers.
    private static double[]? Rgb(IReadOnlyList<double>? color) =>
        color is null ? null : [.. (color.Count == 1 ? [color[0], color[0], color[0]] : color).Select(c => Math.Round(c * 255))];

    [Fact]
    public void ExportThenImportKeepsTheMeaningOfEveryAnnotation()
    {
        var source = Marked();
        byte[] xml = PdfXfdf.Write(PdfFdf.Export(source, "doc.pdf"));
        var read = PdfXfdf.Read(xml);
        Assert.Equal("doc.pdf", read.FileName);
        Assert.Equal(PdfAnnotations.ReadAll(source).Count(a => a.Type != AnnotationType.Popup), read.Annotations.Count);

        var target = Blank(2);
        var result = PdfFdf.Import(target, read);
        Assert.Equal(0, result.Skipped);
        Assert.Equal(0, result.WithoutAppearance);

        var before = PdfAnnotations.ReadAll(source).ToDictionary(a => a.Name!);
        foreach (var after in PdfAnnotations.ReadAll(Reopen(target)))
        {
            var was = before[after.Name!];
            Assert.Equal(was.Subtype, after.Subtype);
            Assert.Equal(was.Rect, after.Rect);
            Assert.Equal(was.Contents, after.Contents);
            Assert.Equal(was.Title, after.Title);
            Assert.Equal(was.Subject, after.Subject);
            Assert.Equal(was.Modified, after.Modified);
            Assert.Equal(Rgb(was.Color), Rgb(after.Color));
            Assert.Equal(Rgb(was.InteriorColor), Rgb(after.InteriorColor));
            Assert.Equal(was.Opacity, after.Opacity);
            Assert.Equal(was.QuadPoints, after.QuadPoints);
            Assert.Equal(was.Vertices, after.Vertices);
            Assert.Equal(was.Line, after.Line);
            Assert.Equal(was.InkList.Select(p => p.ToArray()), after.InkList.Select(p => p.ToArray()));
            Assert.Equal((was.StartEnding, was.EndEnding), (after.StartEnding, after.EndEnding));
            Assert.Equal(was.Border.Style, after.Border.Style);
            Assert.Equal(was.Border.Dash, after.Border.Dash);
            Assert.Equal(was.Cloud, after.Cloud);
            Assert.Equal(was.Flags, after.Flags);
            Assert.Equal(was.IconName, after.IconName);
            Assert.Equal(was.DefaultAppearance, after.DefaultAppearance);
            Assert.Equal(was.Alignment, after.Alignment);
            Assert.True(after.HasAppearance);
        }
        var thread = PdfComments.List(target).Single(c => c.Text == "şiir & <tag>");
        Assert.Equal("yanıt", Assert.Single(thread.Replies).Contents);
    }

    [Fact]
    public void ReadsAnXfdfAsAcrobatWritesIt()
    {
        const string xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
              <f href="C:\docs\a.pdf"/>
              <fields>
                <field name="person"><field name="name"><value>Ayşe</value></field><field name="langs"><value>tr</value><value>en</value></field></field>
              </fields>
              <annots>
                <highlight color="#FFFF00" flags="print" name="h1" page="0" rect="10,20,110,34" title="Ali" subject="Highlight"
                           date="D:20260301090000+00'00'" coords="10,34,110,34,10,20,110,20" opacity="0.5">
                  <contents>nice</contents>
                  <popup flags="print,nozoom,norotate" open="no" page="0" rect="120,20,220,100"/>
                </highlight>
                <freetext page="1" rect="50,50,250,100" name="f1" justification="2" flags="print">
                  <contents>text &amp; more</contents>
                  <defaultappearance>/Helv 14 Tf 1 0 0 rg</defaultappearance>
                  <defaultstyle>font: Helvetica 14pt</defaultstyle>
                  <contents-richtext><body xmlns="http://www.w3.org/1999/xhtml"><p><span style="font-weight:bold">text</span> &amp; more</p></body></contents-richtext>
                </freetext>
                <unheardof page="0"/>
                <square page="0" rect="5,5,25,25" name="s1" style="cloudy" intensity="1" interior-color="#00FF00" color="#0000FF" width="2"/>
                <ink page="0" rect="0,0,40,40" name="i1"><inklist><gesture>1,2;3,4;5,6</gesture><gesture>7,8;9,10</gesture></inklist></ink>
              </annots>
            </xfdf>
            """;
        var fdf = PdfXfdf.Read(xml);
        Assert.Equal(@"C:\docs\a.pdf", fdf.FileName);
        Assert.Equal(["person.name", "person.langs"], fdf.FlatFields().Select(f => f.Key));
        Assert.Equal("Ayşe", PdfText.Decode(((PdfString)fdf.FlatFields()[0].Value!).Bytes));
        Assert.Equal(2, ((PdfArray)fdf.FlatFields()[1].Value!).Items.Count);
        Assert.Equal(4, fdf.Annotations.Count);

        var document = Blank(2);
        var result = PdfFdf.Import(document, fdf);
        Assert.Equal(new FdfImportResult(5, 0, 0), result);
        var onFirst = PdfAnnotations.Read(document, document.Pages[0]);
        var highlight = onFirst.Single(a => a.Type == AnnotationType.Highlight);
        Assert.Equal("nice", highlight.Contents);
        Assert.Equal(0.5, highlight.Opacity);
        Assert.Equal([1d, 1d, 0d], highlight.Color);
        Assert.Equal(AnnotationFlags.Print, highlight.Flags);
        Assert.NotNull(highlight.Popup);
        var popup = onFirst.Single(a => a.Type == AnnotationType.Popup);
        Assert.Equal(new PdfRect(120, 20, 220, 100), popup.Rect);
        var square = onFirst.Single(a => a.Type == AnnotationType.Square);
        Assert.Equal(1, square.Cloud);
        Assert.Equal(2, square.Border.Width);
        Assert.Equal([5d, 6d], onFirst.Single(a => a.Type == AnnotationType.Ink).InkList[0].Skip(4));
        var text = PdfAnnotations.Read(document, document.Pages[1]).Single();
        Assert.Equal(2, text.Alignment);
        Assert.Contains("<span style=\"font-weight:bold\">text</span>", text.RichText);
        Assert.Equal("text & more", PdfRichText.ToPlain(text.RichText!));
        Reopen(document);
    }

    [Fact]
    public void TextWithMarkupCharactersAndNewlinesSurvives()
    {
        var document = Blank(1);
        string tricky = "a < b && c > d \"quoted\" 'single'\nsecond line\ttab";
        new PdfAnnotationWriter(document).AddNote(document.Pages[0], new PdfRect(10, 10, 30, 30), new AnnotationInfo("A", tricky));
        var target = Blank(1);
        PdfFdf.Import(target, PdfXfdf.Read(PdfXfdf.Write(PdfFdf.Export(document))));
        Assert.Equal(tricky, PdfAnnotations.Read(target, target.Pages[0]).Single().Contents);
    }

    [Fact]
    public void FieldValuesRoundTrip()
    {
        var fdf = new FdfFile();
        fdf.Fields.Add(new FdfField("a", PdfText.ToObject("bir"), []));
        fdf.Fields.Add(new FdfField("g", null, [new FdfField("b", new PdfName("Yes"), []), new FdfField("c", new PdfArray([PdfText.ToObject("x"), PdfText.ToObject("y")]), [])]));
        var read = PdfXfdf.Read(PdfXfdf.Write(fdf));
        Assert.Equal(["a", "g.b", "g.c"], read.FlatFields().Select(f => f.Key));
        Assert.Equal("Yes", PdfText.Decode(((PdfString)read.FlatFields()[1].Value!).Bytes));
        Assert.Equal(2, ((PdfArray)read.FlatFields()[2].Value!).Items.Count);
    }

    [Fact]
    public void OutputIsWellFormedUtf8WithNamespace()
    {
        byte[] bytes = PdfXfdf.Write(PdfFdf.Export(Marked()));
        string xml = Encoding.UTF8.GetString(bytes);
        Assert.StartsWith("<?xml", xml);
        Assert.Contains("xmlns=\"http://ns.adobe.com/xfdf/\"", xml);
        Assert.Equal((byte)'<', bytes[0]);
        Assert.Contains("şiir", xml);
    }

    [Theory]
    [InlineData("not xml at all")]
    [InlineData("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots>")]
    [InlineData("<other/>")]
    [InlineData("<!DOCTYPE xfdf [<!ENTITY x SYSTEM \"file:///c:/windows/win.ini\">]><xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><fields><field name=\"a\"><value>&x;</value></field></fields></xfdf>")]
    public void BadXmlIsDamagedNotACrash(string xml)
    {
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => PdfXfdf.Read(xml)).Problem);
    }

    [Fact]
    public void ValuesThatAreNotNumbersDoNotBreakImport()
    {
        var fdf = PdfXfdf.Read("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><square page=\"0\" rect=\"a,b,c,d\" color=\"red\" width=\"x\" coords=\"1,2\"/><square page=\"0\" rect=\"1,1,2,2\" opacity=\"NaN\"/><square page=\"-4\" rect=\"1,1,9,9\"/></annots></xfdf>");
        var document = Blank(1);
        var result = PdfFdf.Import(document, fdf);
        Assert.Equal(2, result.Imported);
        Assert.Equal(1, result.Skipped);
    }
}
