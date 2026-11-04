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
}
