using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Places that actions, hidden content and file names can live.
public class SanitizeReachTests
{
    private static byte[] File(string catalogExtra, string pageExtra, params (int Number, string Body)[] more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R {pageExtra}>>");
        foreach (var (number, body) in more) pdf.Obj(number, body);
        return pdf.Finish();
    }

    private static SanitizeResult Run(byte[] file, SanitizeOptions? options = null)
    {
        using var document = PdfDocument.Open(file);
        return new PdfSanitizer(document).Run(options ?? new SanitizeOptions());
    }

    [Fact]
    public void AVeryLongActionChainDoesNotOverflowTheStack()
    {
        const int Length = 30_000;
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 100 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        for (int i = 0; i < Length; i++) pdf.Obj(100 + i, $"<</S /Named /N /NextPage /Next {101 + i} 0 R>>");
        pdf.Obj(100 + Length, "<</S /JavaScript /JS (MARKERJS1)>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var sanitizer = new PdfSanitizer(document);
        sanitizer.Scan();
        Assert.False(OptimizeKit.Everywhere(sanitizer.Run(new SanitizeOptions()).Bytes, "MARKERJS1"));
    }

    [Theory]
    [InlineData("<</Next 8 0 R>>")]
    [InlineData("<</S /GoToDp /Next 8 0 R>>")]
    public void AnActionWithoutAKnownTypeStillHasItsChainFiltered(string action)
    {
        var result = Run(File("/OpenAction 5 0 R", "", (5, action), (8, "<</S /JavaScript /JS (MARKERJS1)>>")));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERJS1"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
    }

    [Fact]
    public void ALinkPartialActionIsFiltered()
    {
        var result = Run(File("", "/Annots [5 0 R]", (5, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /PA <</S /URI /URI (http://MARKERURL.example/)>>>>")));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERURL"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.ExternalLinks));
    }

    [Fact]
    public void ARenditionThatRunsAScriptCountsAsJavaScript()
    {
        byte[] file = File("/OpenAction 5 0 R", "", (5, "<</S /Rendition /OP 0 /JS (MARKERJS1)>>"));
        var bothOff = Run(file, new SanitizeOptions { JavaScript = false, LaunchActions = false });
        Assert.True(OptimizeKit.Everywhere(bothOff.Bytes, "MARKERJS1"));
        var scriptsOff = Run(file, new SanitizeOptions { JavaScript = false });
        Assert.False(OptimizeKit.Everywhere(scriptsOff.Bytes, "MARKERJS1"));
        Assert.Equal(1, SanitizeKit.Count(scriptsOff.Removed, SanitizeItem.LaunchActions));
        var launchOff = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.False(OptimizeKit.Everywhere(launchOff.Bytes, "MARKERJS1"));
        Assert.Equal(1, SanitizeKit.Count(launchOff.Removed, SanitizeItem.JavaScript));
    }

    [Theory]
    [InlineData("Templates")]
    [InlineData("Pages")]
    public void NamedAndTemplatePagesGoWithTheScripts(string tree)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /Names <</{tree} <</Names [(t) 6 0 R]>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>");
        pdf.Stream(7, "", "BT (MARKERHIDDENPAGE) Tj ET");
        var result = Run(pdf.Finish());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERHIDDENPAGE"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
        Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
    }

    [Fact]
    public void AlternatePresentationsGoWithTheScripts()
    {
        var result = Run(File("/Names <</AlternatePresentations <</Names [(s) 6 0 R]>>>>", "", (6, "<</Type /SlideShow /Subtype /Embedded /Resources <</Names [(MARKERSLIDE) 3 0 R]>>>>")));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERSLIDE"));
    }

    [Fact]
    public void AThreeDimensionalScriptGoesWithTheScripts()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>");
        pdf.Obj(5, "<</Type /Annot /Subtype /3D /Rect [0 0 50 50] /3DD 6 0 R>>");
        pdf.Stream(6, "/Type /3D /Subtype /U3D /OnInstantiate 7 0 R", "U3D");
        pdf.Stream(7, "", "app.alert('MARKERJS1')");
        var result = Run(pdf.Finish());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERJS1"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
    }

    [Fact]
    public void RelatedFilesGoWithTheEmbeddedFile()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction <</S /GoToR /F 5 0 R /D [0 /Fit]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(5, "<</Type /Filespec /F (a.txt) /EF <</F 6 0 R>> /RF <</F 8 0 R>>>>");
        pdf.Stream(6, "/Type /EmbeddedFile", "MARKERATTACH");
        pdf.Obj(8, "[(a.txt) 9 0 R]");
        pdf.Stream(9, "/Type /EmbeddedFile", "MARKERRELATED");
        var result = Run(pdf.Finish(), new SanitizeOptions { LaunchActions = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERATTACH"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERRELATED"));
    }

    [Fact]
    public void FilePathsInIndirectStringsAndLaunchWindowsAreCut()
    {
        byte[] file = File("/OpenAction 5 0 R", "/Annots [7 0 R]",
            (5, "<</S /Launch /Win <</F (C:\\\\Users\\\\MARKERNAME\\\\run.exe) /D (C:\\\\Users\\\\MARKERDIR) /P (-x)>>>>"),
            (6, "(C:\\\\Users\\\\MARKERINDIRECT\\\\a.txt)"),
            (7, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 9 9] /FS <</Type /Filespec /F 6 0 R /UF 6 0 R>>>>"));
        var result = Run(file, new SanitizeOptions { LaunchActions = false, EmbeddedFiles = false });
        foreach (string leak in new[] { "MARKERNAME", "MARKERDIR", "MARKERINDIRECT" }) Assert.False(OptimizeKit.Everywhere(result.Bytes, leak), leak);
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "run.exe"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "a.txt"));
    }

    [Fact]
    public void ALaunchParameterStringIsDropped()
    {
        byte[] file = File("/OpenAction 5 0 R", "", (5, "<</S /Launch /Win <</F (cmd.exe) /P (/c C:\\Users\\MARKERNAME\\run.bat)>>>>"));
        var result = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERNAME"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.FilePaths));
    }

    [Fact]
    public void ASubmitAddressIsNotAFilePath()
    {
        const string Address = "https://forms.example/app/x/post";
        byte[] file = File("/OpenAction 5 0 R", "", (5, $"<</S /SubmitForm /F <</FS /URL /F ({Address})>>>>"));
        var result = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, Address));
        Assert.Equal(0, SanitizeKit.Count(result.Removed, SanitizeItem.FilePaths));
    }

    [Fact]
    public void AnOpiFileNameIsCutToTheFileName()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im0 5 0 R>>>> /Contents 6 0 R>>");
        pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /OPI <</2.0 <</Type /OPI /Version 2.0 /F (/home/MARKERUSER/pic.tif)>>>>", "H");
        pdf.Stream(6, "", "q 10 0 0 10 0 0 cm /Im0 Do Q");
        var result = Run(pdf.Finish());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERUSER"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "pic.tif"));
    }
}
