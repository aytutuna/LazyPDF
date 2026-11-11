using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The report: what it says about the filters, what it keeps of the new file's protection, and when it is refused or dropped.
public sealed class CompareReportTests
{
    private static CompareFlow Flow(ViewModelFixture f) => new(f.Vm, () => new FakeRenderer(), new FakeFonts());

    private static CompareSession Session(byte[] before, byte[] after, string? password = null)
    {
        var session = new CompareSession(new Side(before, "old.pdf", null, null), new Side(after, "new.pdf", password, null), () => new FakeRenderer());
        session.Compare(new CompareOptions(), byPixels: false, dpi: 96, CancellationToken.None);
        return session;
    }

    [Fact]
    public void AProtectedFileStaysProtectedInTheReport()
    {
        using var session = Session(CompareKit.Before(), CompareKit.Locked("pw"), "pw");

        var report = session.Report(Parts.All, new FakeFonts());

        Assert.Throws<PdfReadException>(() => PdfDocument.Open(report));
        using var opened = PdfDocument.Open(report, "pw");
        Assert.True(opened.Pages.Count > session.New.PageCount);
    }

    [Fact]
    public async Task TheReportTabKeepsThePasswordSoNothingIsAskedAgain()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.Locked("pw"), "pw");

        await Flow(f).WriteReportAsync(session, Parts.All);

        Assert.Null(f.Vm.PasswordRequest);
        Assert.Equal("pw", f.Vm.ActiveDocument!.Password);
    }

    [Fact]
    public async Task AFileThatLimitsReadersCannotBeCopiedIntoAReport()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), Pdfs.Restricted(PdfPermissions.Print));

        await Flow(f).WriteReportAsync(session, Parts.All);

        Assert.False(session.CanReport);
        Assert.Equal("Report not allowed", f.Vm.Message!.Title);
        Assert.Equal("open.pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public async Task AFilteredReportSaysSoInItsNames()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.After());

        await Flow(f).WriteReportAsync(session, Parts.Forms);

        Assert.Equal("Comparison, filtered - new.pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public async Task NoReportIsWrittenWhenTheFiltersLeaveNothingOfRealDifferences()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.After());

        await Flow(f).WriteReportAsync(session, Parts.Pictures);

        Assert.Equal("Nothing to report", f.Vm.Message!.Title);
        Assert.Equal("open.pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public async Task TwoFilesThatAreTheSameStillGetAReport()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.Before());

        await Flow(f).WriteReportAsync(session, Parts.Pictures);

        Assert.Null(f.Vm.Message);
        Assert.Equal("Comparison, filtered - new.pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public void LeavingPagesOutLeavesRemovedPagesOutOfTheSummary()
    {
        using var session = CompareKit.Session(Pdfs.Text(2, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."), Pdfs.Text(1, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."));
        Assert.Contains(session.Result!.Pages, p => p.IsRemoved);

        Assert.Contains(ChangeParts.Only(session.Result!, Parts.Text | Parts.Details).Pages, p => !p.IsRemoved);
        Assert.DoesNotContain(ChangeParts.Only(session.Result!, Parts.Text | Parts.Details).Pages, p => p.IsRemoved);
        Assert.Contains(ChangeParts.Only(session.Result!, Parts.All).Pages, p => p.IsRemoved);
    }

    [Fact]
    public async Task CancellingDropsTheReport()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.After());
        var host = new CancellingHost();

        await new CompareFlow(host, () => new FakeRenderer(), new FakeFonts()).WriteReportAsync(session, Parts.All);

        Assert.Equal(0, host.Opened);
    }

    [Fact]
    public async Task APixelComparisonHasAReportToo()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Painted());
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: true, dpi: 96, CancellationToken.None);

            await Flow(f).WriteReportAsync(session, Parts.All);

            var tab = f.Vm.ActiveDocument!;
            Assert.Equal("Comparison - new.pdf", tab.Title);
            Assert.True(tab.PageCount > session.New.PageCount);
        }
    }

    [Fact]
    public void TheCsvQuotesWhatNeedsItAndStartsWithTheByteOrderMark()
    {
        using var session = Session(Pdfs.Text(1, "Say \"hi\", friend, once."), Pdfs.Text(1, "Say \"bye\", friend, twice."));

        byte[] csv = session.Csv(Parts.All);

        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, csv[..3]);
        string text = System.Text.Encoding.UTF8.GetString(csv, 3, csv.Length - 3);
        string[] lines = text.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("Kind,Old page,New page,What,Detail", lines[0]);
        Assert.Equal(session.Rows(Parts.All).Count + 1, lines.Length);
        Assert.Contains(lines.Skip(1), l => l.Contains("\"Say \"\"") || l.Contains("\"\"hi\"\"") || l.Contains("\"\"bye\"\""));
        Assert.All(lines.Skip(1), l => Assert.Matches("^[A-Za-z ]+,[0-9]*,[0-9]*,", l));
    }

    [Theory]
    [InlineData("- item", "'- item")]
    [InlineData("=HYPERLINK(\"x\")", "\"'=HYPERLINK(\"\"x\"\")\"")]
    [InlineData("+90 532", "'+90 532")]
    [InlineData("plain", "plain")]
    public void ACsvFieldThatCouldRunAsAFormulaIsKeptAsText(string field, string expected) =>
        Assert.Equal(expected, CompareSession.Field(field));

    [Fact]
    public void ARowOfAPixelComparisonSaysItLooksDifferent()
    {
        using var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Painted());
        session.Compare(new CompareOptions(), byPixels: true, dpi: 96, CancellationToken.None);

        string text = System.Text.Encoding.UTF8.GetString(session.Csv(Parts.All));

        Assert.NotEmpty(session.Rows(Parts.All));
        Assert.Contains("\r\nLooks different,", text);
    }

    [Fact]
    public void APageTooLargeAtTheChosenDetailIsLeftUndrawn()
    {
        using var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Painted());

        session.Compare(new CompareOptions(), byPixels: true, dpi: 1000, CancellationToken.None);

        Assert.Equal(0, session.Looked);
        Assert.Equal(2, session.Undrawn);
        Assert.Null(session.Overlay(0));
    }

    [Fact]
    public void TheTextReportNamesBothFiles()
    {
        using var session = Session(CompareKit.Before(), CompareKit.After());

        string text = session.TextReport(Parts.All);

        Assert.Contains("old.pdf", text);
        Assert.Contains("new.pdf", text);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AFileThatLimitsReadersGetsNoTextOrCsvReport(bool csv)
    {
        using var f = new ViewModelFixture();
        using var session = Session(CompareKit.Before(), Pdfs.Restricted(PdfPermissions.Print));
        string path = Path.Combine(f.Dir.Path, "report.out");

        await Flow(f).SaveReportAsync(session, Parts.All, csv, path);

        Assert.Equal("Report not allowed", f.Vm.Message!.Title);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task ATextReportIsWrittenWithoutOpeningATab()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var session = Session(CompareKit.Before(), CompareKit.After());
        string path = Path.Combine(f.Dir.Path, "report.txt");

        await Flow(f).SaveReportAsync(session, Parts.All, csv: false, path);

        Assert.Contains("new.pdf", File.ReadAllText(path));
        Assert.Equal("Report saved.", f.Vm.Message!.Title);
        Assert.Equal("open.pdf", f.Vm.ActiveDocument!.Title);
    }
}
