using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FileRevisionTests
{
    private static byte[] ThreeRevisions()
    {
        var session = PdfEditSession.Open(SignatureKit.Plain());
        PdfForm.Read(session.Document).AddField(new FieldSpec(FieldKind.Text, "Name", 0, new PdfRect(40, 200, 240, 224)));
        session.Commit("field");
        PdfForm.Read(session.Document).SetValue("Name", "Ada");
        session.Commit("fill");
        return session.Current.ToArray();
    }

    [Fact]
    public void Each_saved_state_of_the_file_is_a_revision_that_opens_on_its_own()
    {
        byte[] file = ThreeRevisions();

        var revisions = PdfRevisions.List(file);

        Assert.Equal([1, 2, 3], revisions.Select(r => r.Number));
        Assert.Equal(file.Length, revisions[^1].End);
        Assert.True(revisions[0].End < revisions[1].End && revisions[1].End < revisions[2].End);
        Assert.Empty(PdfForm.Read(PdfDocument.Open(PdfRevisions.Extract(file, revisions[0]))).Fields);
        var second = PdfForm.Read(PdfDocument.Open(PdfRevisions.Extract(file, revisions[1])));
        Assert.Equal("", second.Find("Name")!.Value ?? "");
        Assert.Equal("Ada", PdfForm.Read(PdfDocument.Open(PdfRevisions.Extract(file, revisions[2]))).Find("Name")!.Value);
    }

    [Fact]
    public void Revisions_agree_with_the_versions_the_edit_session_finds()
    {
        byte[] file = ThreeRevisions();
        var session = PdfEditSession.Open(file);

        Assert.Equal(session.Versions.Select(v => v.End), PdfRevisions.List(file).Select(r => r.End));
    }

    [Fact]
    public void A_signed_file_has_the_revision_the_signature_closed()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki.Instance));

        var revisions = PdfRevisions.List(signed);

        Assert.Equal(2, revisions.Count);
        Assert.Equal(signed.Length, revisions[1].End);
        Assert.False(PdfDocument.Open(PdfRevisions.Extract(signed, revisions[0])).IsSigned);
    }

    [Fact]
    public void A_startxref_that_names_nothing_is_not_a_revision()
    {
        byte[] file = ThreeRevisions();
        string stray = "\nstartxref\n0\n%%EOF\nstartxref\n12\n%%EOF\n";
        byte[] padded = [.. file, .. Encoding.Latin1.GetBytes(stray)];

        Assert.Equal(3, PdfRevisions.List(padded).Count);

        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        pdf.Stream(3, "", "startxref\n9\n%%EOF\n");
        Assert.Single(PdfRevisions.List(pdf.Finish()));
    }

    [Fact]
    public void Bytes_without_a_finished_revision_have_none()
    {
        Assert.Empty(PdfRevisions.List([]));
        Assert.Empty(PdfRevisions.List(Encoding.Latin1.GetBytes("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n")));
        byte[] file = ThreeRevisions();
        Assert.Empty(PdfRevisions.List(file.AsSpan(0, 400).ToArray()));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfRevisions.Extract(file.AsSpan(0, 400).ToArray(), new PdfRevision(1, 500)));
    }

    [Fact]
    public void A_cut_off_tail_leaves_the_revisions_before_it()
    {
        byte[] file = ThreeRevisions();
        var revisions = PdfRevisions.List(file);

        var cut = PdfRevisions.List(file.AsSpan(0, revisions[2].End - 30).ToArray());

        Assert.Equal(revisions.Take(2).Select(r => r.End), cut.Select(r => r.End));
    }
}
