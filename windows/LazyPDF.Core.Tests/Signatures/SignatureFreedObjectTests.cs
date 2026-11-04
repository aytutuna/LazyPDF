using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureFreedObjectTests
{
    [Fact]
    public void A_page_freed_while_the_page_tree_still_lists_it_is_not_allowed()
    {
        byte[] file = SignatureChangeTests.Certified(CertificationLevel.NoChanges);
        int page = PdfDocument.Open(file).Pages[0].Reference.Number;

        byte[] attacked = SignatureChangeTests.Edit(file, d => d.Delete(page));

        var report = SignatureChangeTests.First(attacked);
        Assert.NotEqual(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.PageStructure);
    }

    [Fact]
    public void A_stream_listed_and_then_freed_while_the_signed_page_still_points_at_it_is_not_allowed()
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents [4 0 R 99 0 R]");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        byte[] listed = SignatureRoleTests.AppendRaw(signed, (99, SignatureRawKit.StreamBody(SignatureRawKit.Evil)));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, SignatureKit.Verify(listed)[0].Verdict);

        byte[] freed = SignatureForgeryTests.AppendSection(listed, "", "99 1\n0000000000 00001 f \n");

        var report = SignatureKit.Verify(freed)[0];
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == 99);
    }
}
