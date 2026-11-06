using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfARuleDetailTests
{
    private static byte[] Annotated(string subtype, string entries, PdfALevel level, string intents = "/OutputIntents [6 0 R]") =>
        StandardsKit.Compliant(level, intents: intents, page: "/Annots [9 0 R]", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Annot /Subtype /{subtype} /Rect [10 10 50 50] /F 4 /AP << /N 10 0 R >> {entries}>>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "");
        });

    private static byte[] WithStream(string entries, PdfALevel level) =>
        StandardsKit.Compliant(level, catalog: "/Extra 9 0 R", extra: pdf => pdf.Stream(9, entries, "abc"));

    [Fact]
    public void PolygonAndPolyLineCameWithPdf15()
    {
        foreach (string subtype in new[] { "Polygon", "PolyLine" })
        {
            string vertices = "/Vertices [10 10 50 10 50 50]";
            Assert.Contains("6.5.2", StandardsKit.Clauses(Annotated(subtype, vertices, PdfALevel.A1b), PdfALevel.A1b));
            Assert.DoesNotContain("6.3.1", StandardsKit.Clauses(Annotated(subtype, vertices, PdfALevel.A2b)));
        }
        Assert.DoesNotContain("6.5.2", StandardsKit.Clauses(Annotated("Square", "", PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains(PdfAChecker.AllowedAnnotations(2), a => a == "Polygon");
        Assert.DoesNotContain(PdfAChecker.AllowedAnnotations(1), a => a == "PolyLine");
    }

    [Fact]
    public void FilterRulesFollowThePart()
    {
        Assert.Contains("6.1.7.2", StandardsKit.Clauses(WithStream("/Filter /LZWDecode", PdfALevel.A2b)));
        Assert.Contains("6.1.10", StandardsKit.Clauses(WithStream("/Filter /LZWDecode", PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains(StandardsKit.Check(WithStream("/Filter /Invented", PdfALevel.A2b)).Issues, i => i.Clause == "6.1.7.2" && i.Message.Contains("Invented"));
        Assert.DoesNotContain("6.1.7.2", StandardsKit.Clauses(WithStream("/Filter /FlateDecode", PdfALevel.A2b)));
    }

    [Fact]
    public void ACryptFilterIsOnlyTheIdentityFromPart2()
    {
        Assert.DoesNotContain("6.1.7.2", StandardsKit.Clauses(WithStream("/Filter /Crypt /DecodeParms << /Name /Identity >>", PdfALevel.A2b)));
        Assert.DoesNotContain("6.1.7.2", StandardsKit.Clauses(WithStream("/Filter [/Crypt] /DecodeParms [null]", PdfALevel.A2b)));
        Assert.Contains("6.1.7.2", StandardsKit.Clauses(WithStream("/Filter /Crypt /DecodeParms << /Name /Custom >>", PdfALevel.A2b)));
        Assert.Contains("6.1.10", StandardsKit.Clauses(WithStream("/Filter /Crypt /DecodeParms << /Name /Identity >>", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void AnEmbeddedFileInPart2IsPdfA1OrPdfA2()
    {
        static byte[] Attach(PdfALevel inner) => StandardsKit.Compliant(PdfALevel.A2b, catalog: "/Names << /EmbeddedFiles << /Names [(a.pdf) 9 0 R] >> >>", extra: pdf =>
        {
            pdf.Obj(9, "<</Type /Filespec /F (a.pdf) /UF (a.pdf) /EF << /F 10 0 R >>>>");
            pdf.Stream(10, "/Type /EmbeddedFile", StandardsKit.Compliant(inner));
        });
        StandardsKit.AssertClean(Attach(PdfALevel.A2b));
        Assert.Contains(StandardsKit.Check(Attach(PdfALevel.A3b)).Issues, i => i.Clause == "6.8" && i.Message.Contains("not a PDF/A"));
    }

    [Fact]
    public void ThePdfUaNamespaceNeedsAnExtensionSchema()
    {
        byte[] file = StandardsKit.Compliant(xmp: StandardsKit.Packet(PdfALevel.A2b).Replace("<rdf:Description ", "<rdf:Description xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\" pdfuaid:part=\"1\" "));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.6.2.3.1" && i.Message.Contains("pdfua"));
    }

    [Fact]
    public void TheMetadataStreamIsNotFiltered()
    {
        byte[] plain = StandardsKit.Compliant();
        Assert.DoesNotContain(StandardsKit.Check(plain).Issues, i => i.Message.Contains("/Filter"));
        byte[] filtered = StandardsKit.Compliant(extra: pdf =>
            pdf.Stream(5, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", TestPdf.Deflate(Encoding.UTF8.GetBytes(StandardsKit.Packet(PdfALevel.A2b)))));
        Assert.Contains(StandardsKit.Check(filtered).Issues, i => i.Clause == "6.6.2.1" && i.Message.Contains("/Filter"));
        Assert.Contains("6.7.2", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, extra: pdf =>
            pdf.Stream(5, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", TestPdf.Deflate(Encoding.UTF8.GetBytes(StandardsKit.Packet(PdfALevel.A1b))))), PdfALevel.A1b));
    }

    [Fact]
    public void AnnotationColoursNeedAnRgbIntentInPart1()
    {
        Assert.Contains("6.5.3", StandardsKit.Clauses(Annotated("Square", "/C [1 0 0 0]", PdfALevel.A1b, ""), PdfALevel.A1b));
        Assert.Contains("6.5.3", StandardsKit.Clauses(Annotated("Square", "/IC [0.5]", PdfALevel.A1b, ""), PdfALevel.A1b));
        Assert.DoesNotContain("6.5.3", StandardsKit.Clauses(Annotated("Square", "/C [1 0 0]", PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.5.3", StandardsKit.Clauses(Annotated("Square", "/C []", PdfALevel.A1b, ""), PdfALevel.A1b));
        Assert.DoesNotContain("6.5.3", StandardsKit.Clauses(Annotated("Square", "/C [1 0 0 0]", PdfALevel.A2b, "")));
    }

    [Fact]
    public void NeedsRenderingIsNotAllowedFromPart2()
    {
        Assert.Contains("6.4.2", StandardsKit.Clauses(StandardsKit.Compliant(catalog: "/NeedsRendering false")));
        Assert.DoesNotContain("6.4.2", StandardsKit.Clauses(StandardsKit.Compliant()));
    }

    [Fact]
    public void BlendModesMustBeOnesOfTheStandard()
    {
        static byte[] With(string mode, PdfALevel level = PdfALevel.A2b) => StandardsKit.Compliant(level, resources: $"/ExtGState <</G0 << /BM {mode} >>>>");
        StandardsKit.AssertClean(With("/Multiply"));
        StandardsKit.AssertClean(With("/Luminosity"));
        Assert.Contains(StandardsKit.Check(With("/Glow")).Issues, i => i.Clause == "6.2.10" && i.Message.Contains("Glow"));
        Assert.Contains("6.2.10", StandardsKit.Clauses(With("[/Multiply /Glow]")));
        Assert.Contains("6.4", StandardsKit.Clauses(With("/Multiply", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void TheConformanceLetterIsMatchedAsWritten()
    {
        static byte[] Packet(PdfALevel level, string from, string to) =>
            StandardsKit.Compliant(level, xmp: StandardsKit.Packet(level).Replace($"<pdfaid:conformance>{from}<", $"<pdfaid:conformance>{to}<"));
        Assert.Contains("6.6.4", StandardsKit.Clauses(Packet(PdfALevel.A2b, "B", "b")));
        Assert.Contains("6.7.11", StandardsKit.Clauses(Packet(PdfALevel.A1b, "B", "U"), PdfALevel.A1b));
        Assert.DoesNotContain("6.6.4", StandardsKit.Clauses(Packet(PdfALevel.A2b, "B", "U")));
        Assert.DoesNotContain("6.7.11", StandardsKit.Clauses(Packet(PdfALevel.A1b, "B", "A"), PdfALevel.A1b));
    }

    [Fact]
    public void ALabProfileMayHaveThreeComponents()
    {
        byte[] lab = (byte[])PdfASrgb.SrgbProfile.Clone();
        Encoding.ASCII.GetBytes("Lab ").CopyTo(lab, 16);
        Assert.Null(PdfAChecker.IccProblem(lab, 3, 4));
        Assert.NotNull(PdfAChecker.IccProblem(lab, 1, 4));
        Assert.NotNull(PdfAChecker.IccProblem(lab, 3, 4, outputIntent: true));
        byte[] scanner = (byte[])PdfASrgb.SrgbProfile.Clone();
        Encoding.ASCII.GetBytes("scnr").CopyTo(scanner, 12);
        Assert.Null(PdfAChecker.IccProblem(scanner, 3, 4));
        Assert.NotNull(PdfAChecker.IccProblem(scanner, 3, 4, outputIntent: true));
    }

    [Fact]
    public void ANegativeZeroWidthIsWrittenWithItsSign()
    {
        Assert.Contains("is -0 but", PdfAText.WidthDiffers(65, -0.0, 5));
    }
}
