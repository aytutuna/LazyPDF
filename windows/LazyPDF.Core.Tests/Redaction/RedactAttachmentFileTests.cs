using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Attachments crafted so that a reader other than the check sees the marked word: each ends as found or as not checked, never
// as clean. The files are in Tests/Fixtures/golden/redaction; the Swift twin reads the same ones.
public class RedactAttachmentFileTests
{
    private static byte[] Case(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "redaction", name));

    private static List<string> Problems(byte[] attachment)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Names <</EmbeddedFiles <</Names [(original) 6 0 R]>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", "BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET");
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Obj(6, "<</Type /Filespec /F (original) /EF <</F 7 0 R>>>>");
        pdf.Stream(7, "/Type /EmbeddedFile", attachment);
        using var document = PdfDocument.Open(pdf.Finish());
        return [.. new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER")).Verification.Problems];
    }

    private static readonly string Found = RedactionText.StillInFile(RedactionText.AttachedFile(5));
    private static readonly string Unread = RedactionText.NotChecked(RedactionText.AttachedFile(5));

    [Theory]
    [InlineData("z0-proper.zip")]
    [InlineData("z6-data-descriptor.zip")]
    [InlineData("g0-proper.gz")]
    [InlineData("g4-empty-member-then-secret.gz")]
    [InlineData("g5-empty-blocks-then-secret.gz")]
    [InlineData("i1-incremental.pdf")]
    public void ContainerThatIsReadWholeShowsTheWord(string name) => Assert.Equal([Found], Problems(Case(name)));

    [Theory]
    [InlineData("z1-unlisted-local.zip")]
    [InlineData("z2-decoy-directory.zip")]
    [InlineData("z3-zero-count-offset-past-end.zip")]
    [InlineData("z3b-zero-count-offset-at-end.zip")]
    [InlineData("z3c-zero-count-offset-zero.zip")]
    [InlineData("z4-size-zero.zip")]
    [InlineData("z4b-size-short.zip")]
    [InlineData("z5-disk-count-differs.zip")]
    [InlineData("z7-slack-after-stream.zip")]
    [InlineData("p1-jpeg-zip.zip")]
    [InlineData("p2-text-zip.zip")]
    [InlineData("g2-bad-header-crc.gz")]
    [InlineData("g3-reserved-flag.gz")]
    [InlineData("g6-trailing-garbage-1f.gz")]
    [InlineData("g7-plain-then-1f8b-garbage.gz")]
    [InlineData("c1-secret.cab")]
    [InlineData("c2-secret.zlib")]
    public void ContainerThatIsNotAccountedForByteForByteIsNotChecked(string name) => Assert.Equal([Unread], Problems(Case(name)));

    [Fact]
    public void ZeroPaddingAfterTheLastGzipMemberIsNotAMember() => Assert.Empty(Problems(Case("g1-trailing-zeros.gz")));

    [Fact]
    public void ShortCompressedDataIsNotCheckedWhateverItsSize()
    {
        // 8 bytes of a zlib stream: nothing like the 512 bytes the entropy test wanted.
        Assert.Equal([Unread], Problems([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]));
    }

    [Fact]
    public void TextIsSearchedAndFoundOrClean()
    {
        Assert.Equal([Found], Problems(System.Text.Encoding.Latin1.GetBytes("notes about ZQXMARKER")));
        Assert.Empty(Problems(System.Text.Encoding.Latin1.GetBytes("notes about nothing")));
    }

    [Fact]
    public void EntryThatDoesNotMatchItsChecksumIsNotChecked()
    {
        var packed = Case("z0-proper.zip");
        // The CRC-32 of the entry sits in both headers; spoil the one of the directory.
        int directory = packed.AsSpan().IndexOf("PK\u0001\u0002"u8);
        packed[directory + 16] ^= 0xFF;
        Assert.Equal([Unread], Problems(packed));
    }

    [Fact]
    public void ManyEndOfFileMarkersAreCountedInLinearTime()
    {
        // Each marker starts a revision to read; past eight the rest is not checked, and finding them must not cost more.
        byte[] data = [.. "%PDF-1.7\n"u8, .. Enumerable.Repeat("%%EOF\n"u8.ToArray(), 400_000).SelectMany(b => b)];
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.Equal([Unread], Problems(data));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(60), watch.Elapsed.ToString());
    }
}
