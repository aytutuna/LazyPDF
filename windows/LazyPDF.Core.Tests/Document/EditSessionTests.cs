using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EditSessionTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("lazypdf-session").FullName;

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    private static void Retitle(PdfEditSession session, string title) =>
        session.Document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes(title), isHex: false);

    private static string Title(PdfEditSession session) => SaveFixtures.Title(session.Document);

    [Fact]
    public void FileThatIsNotAPdfIsRefused()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfEditSession.Open("not a pdf"u8.ToArray()));
        Assert.Equal(PdfReadProblem.NotPdf, e.Problem);
    }

    [Fact]
    public void CommitAppendsAnUpdateAndUndoRedoMoveTheEnd()
    {
        byte[] original = SaveFixtures.Table();
        var session = PdfEditSession.Open(original);
        Assert.Equal(original, session.Current.ToArray());
        Assert.False(session.CanUndo);
        Assert.False(session.CanRedo);

        Retitle(session, "One");
        Assert.True(session.Commit("Title one"));
        byte[] afterOne = session.Current.ToArray();
        Retitle(session, "Two");
        Assert.True(session.Commit("Title two"));
        byte[] afterTwo = session.Current.ToArray();

        Assert.True(afterOne.AsSpan(0, original.Length).SequenceEqual(original));
        Assert.True(afterTwo.AsSpan(0, afterOne.Length).SequenceEqual(afterOne));
        Assert.Equal("Two", Title(session));
        Assert.Equal("Title two", session.UndoLabel);

        Assert.True(session.Undo());
        Assert.Equal(afterOne, session.Current.ToArray());
        Assert.Equal("One", Title(session));
        Assert.Equal("Title one", session.UndoLabel);
        Assert.Equal("Title two", session.RedoLabel);
        Assert.True(session.CanRedo);

        Assert.True(session.Undo());
        Assert.Equal(original, session.Current.ToArray());
        Assert.Equal("Original title", Title(session));
        Assert.False(session.CanUndo);
        Assert.False(session.Undo());

        Assert.True(session.Redo());
        Assert.True(session.Redo());
        Assert.Equal(afterTwo, session.Current.ToArray());
        Assert.Equal("Two", Title(session));
        Assert.False(session.Redo());
        Assert.Null(session.RedoLabel);
    }

    [Fact]
    public void CommitWithNothingChangedAddsNothing()
    {
        var session = PdfEditSession.Open(SaveFixtures.Table());
        byte[] before = session.Current.ToArray();
        Assert.False(session.Commit("Nothing"));
        Assert.False(session.CanUndo);
        Assert.Equal(before, session.Current.ToArray());
        _ = session.Document.Pages[0].Contents();
        Assert.False(session.Commit("Still nothing"));
    }

    [Fact]
    public void CommitAfterUndoDropsWhatCouldBeRedone()
    {
        var session = PdfEditSession.Open(SaveFixtures.Table());
        Retitle(session, "A");
        session.Commit("A");
        Retitle(session, "B");
        session.Commit("B");
        session.Undo();
        Retitle(session, "C");
        session.Commit("C");
        Assert.False(session.CanRedo);
        Assert.Equal("C", Title(session));
        session.Undo();
        Assert.Equal("A", Title(session));
        session.Undo();
        Assert.Equal("Original title", Title(session));
    }

    [Fact]
    public void UndoDropsChangesNotYetCommitted()
    {
        var session = PdfEditSession.Open(SaveFixtures.Table());
        Retitle(session, "A");
        session.Commit("A");
        Retitle(session, "Pending");
        Assert.True(session.Document.HasChanges);
        session.Undo();
        Assert.False(session.Document.HasChanges);
        Assert.Equal("Original title", Title(session));
    }

    [Fact]
    public void CurrentIsAlwaysACompleteFileAndNeverChangesInPlace()
    {
        var session = PdfEditSession.Open(SaveFixtures.Table());
        var first = session.Current;
        Retitle(session, "A");
        session.Commit("A");
        Assert.Equal(SaveFixtures.Table(), first.ToArray());
        using var pig = UglyToad.PdfPig.PdfDocument.Open(session.Current.ToArray());
        Assert.Equal("A", pig.Information.Title);
        Assert.Empty(PdfDocument.Open(session.Current.ToArray()).Repairs);
    }

    [Fact]
    public void ManyCommitsStayReadable()
    {
        var session = PdfEditSession.Open(SaveFixtures.Table());
        for (int i = 0; i < 60; i++)
        {
            Retitle(session, $"Title {i}");
            session.Document.Pages[i % 2].Dictionary["Rotate"] = new PdfNumber(i % 4 * 90);
            Assert.True(session.Commit($"Edit {i}"));
        }
        var final = PdfDocument.Open(session.Current.ToArray());
        Assert.Equal("Title 59", SaveFixtures.Title(final));
        Assert.Equal(61, PdfVersion.Find(final).Count);
        for (int i = 0; i < 60; i++) Assert.True(session.Undo());
        Assert.Equal("Original title", Title(session));
    }

    [Fact]
    public void IsDirtyIsAgainstTheLastSave()
    {
        string path = Path.Combine(_folder, "a.pdf");
        File.WriteAllBytes(path, SaveFixtures.Table());
        var session = PdfEditSession.Open(path);
        Assert.False(session.IsDirty);

        Retitle(session, "A");
        Assert.True(session.IsDirty);
        session.Commit("A");
        Assert.True(session.IsDirty);

        session.Save(path);
        Assert.False(session.IsDirty);
        Retitle(session, "B");
        session.Commit("B");
        Assert.True(session.IsDirty);
        session.Undo();
        Assert.False(session.IsDirty);
        session.Undo();
        Assert.True(session.IsDirty);
        session.Redo();
        Assert.False(session.IsDirty);

        // A new step made after going back past the save loses that state for good.
        session.Undo();
        Retitle(session, "C");
        session.Commit("C");
        session.Undo();
        session.Redo();
        Assert.True(session.IsDirty);
    }

    [Fact]
    public void SaveWritesTheBufferAndCommitsWhatWaits()
    {
        string path = Path.Combine(_folder, "b.pdf");
        File.WriteAllBytes(path, SaveFixtures.Table());
        var session = PdfEditSession.Open(path);
        Retitle(session, "Waiting");
        session.Save(path);

        byte[] saved = File.ReadAllBytes(path);
        Assert.Equal(session.Current.ToArray(), saved);
        Assert.Equal("Waiting", SaveFixtures.Title(PdfDocument.Open(saved)));
        Assert.Equal([path], Directory.GetFileSystemEntries(_folder));
        Assert.True(session.CanUndo);
    }

    [Fact]
    public void SaveCompactDropsTheHistory()
    {
        string path = Path.Combine(_folder, "c.pdf");
        var session = PdfEditSession.Open(SaveFixtures.Table());
        for (int i = 0; i < 10; i++)
        {
            Retitle(session, $"Version {i}");
            session.Commit($"Edit {i}");
        }
        long before = session.Current.Length;
        session.SaveCompact(path);

        Assert.True(File.ReadAllBytes(path).Length < before);
        Assert.False(session.CanUndo);
        Assert.False(session.IsDirty);
        Assert.Equal("Version 9", Title(session));
        Assert.Single(session.Versions);
        Retitle(session, "After");
        session.Commit("After");
        Assert.True(session.Undo());
        Assert.Equal("Version 9", Title(session));
        Assert.False(session.CanUndo);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(path);
        Assert.Equal("Version 9", pig.Information.Title);
    }

    [Fact]
    public void SaveCompactKeepsEncryption()
    {
        string path = Path.Combine(_folder, "d.pdf");
        var session = PdfEditSession.Open(SaveFixtures.Make("aes256"));
        Retitle(session, "Locked");
        session.Commit("Locked");
        session.SaveCompact(path);
        Assert.True(PdfDocument.Open(path).IsEncrypted);
        Assert.Equal("Locked", SaveFixtures.Title(PdfDocument.Open(path)));
    }

    [Fact]
    public void EncryptedFileWithAPasswordIsEditedAndSaved()
    {
        var security = PdfSecurity.Create("secret", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, SaveFixtures.FileId);
        byte[] file = PdfDocument.Open(SaveFixtures.Table()).SaveRewrite(new PdfSaveOptions(Security: security));
        Assert.Throws<PdfReadException>(() => PdfEditSession.Open(file));

        string path = Path.Combine(_folder, "e.pdf");
        var session = PdfEditSession.Open(file, "secret");
        Retitle(session, "Edited");
        session.Commit("Edit");
        session.Undo();
        session.Redo();
        session.Save(path);
        Assert.Equal("Edited", SaveFixtures.Title(PdfDocument.Open(path, "secret")));
    }

    [Fact]
    public void VersionsListTheFilesOwnRevisionsAndCanBeExtracted()
    {
        byte[] v1 = SaveFixtures.Table();
        var document = PdfDocument.Open(v1);
        document.Info!["Title"] = new PdfString([50], isHex: false);
        byte[] v2 = document.SaveIncremental();
        document = PdfDocument.Open(v2);
        document.Info!["Title"] = new PdfString([51], isHex: false);
        byte[] v3 = document.SaveIncremental();

        var session = PdfEditSession.Open(v3);
        Assert.Equal([v1.Length, v2.Length, v3.Length], session.Versions.Select(v => v.End));
        Assert.Equal([1, 2, 3], session.Versions.Select(v => v.Number));
        Assert.Equal(v1, session.ExtractVersion(session.Versions[0]));
        Assert.Equal(v2, session.ExtractVersion(session.Versions[1]));

        string path = Path.Combine(_folder, "v.pdf");
        session.SaveVersion(session.Versions[1], path);
        Assert.Equal("2", SaveFixtures.Title(PdfDocument.Open(path)));
        Retitle(session, "New");
        session.Commit("New");
        Assert.Equal(3, session.Versions.Count);
        Assert.Equal(v1, session.ExtractVersion(session.Versions[0]));
    }

    [Theory]
    [InlineData("stream")]
    [InlineData("hybrid")]
    [InlineData("aes128")]
    public void VersionsOfOtherLayouts(string kind)
    {
        var document = PdfDocument.Open(SaveFixtures.Make(kind));
        document.Info!["Title"] = new PdfString([50], isHex: false);
        var session = PdfEditSession.Open(document.SaveIncremental());
        Assert.Equal(2, session.Versions.Count);
        string path = Path.Combine(_folder, "x.pdf");
        session.SaveVersion(session.Versions[0], path);
        Assert.Equal("Original title", SaveFixtures.Title(PdfDocument.Open(path)));
    }

    [Fact]
    public void RebuiltFileHasNoVersionsButCanStillBeEdited()
    {
        var session = PdfEditSession.Open(TestPdf.Replace(SaveFixtures.Table(), "startxref", "startxxxxx"));
        Assert.Empty(session.Versions);
        Retitle(session, "Fixed");
        Assert.True(session.Commit("Fix"));
        Assert.Empty(PdfDocument.Open(session.Current.ToArray()).Repairs);
        Assert.Single(PdfEditSession.Open(session.Current.ToArray()).Versions);
    }

    [Fact]
    public void VersionIsNotMadeOfAStartxrefInsideStreamData()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>");
        pdf.Stream(4, "", "startxref\n9\n%%EOF\n");
        var session = PdfEditSession.Open(pdf.Finish());
        Assert.Single(session.Versions);
    }

    [Theory]
    [InlineData("table")]
    [InlineData("stream")]
    public void PastTheSectionLimitTheNextUpdateIsAFullSection(string kind)
    {
        var session = PdfEditSession.Open(SaveFixtures.Make(kind));
        for (int i = 1; i <= PdfDocument.MaxSections + 4; i++)
        {
            Retitle(session, "Title " + i);
            Assert.True(session.Commit("Title"));
            if (i % 500 == 0) Assert.False(session.Document.XrefRebuilt);
        }
        Assert.False(session.Document.XrefRebuilt);
        Assert.True(session.Document.SectionOffsets.Count < PdfDocument.MaxSections);

        var reopened = PdfDocument.Open(session.Current.ToArray());
        Assert.False(reopened.XrefRebuilt);
        Assert.Equal("Title " + (PdfDocument.MaxSections + 4), SaveFixtures.Title(reopened));
        Assert.Equal(2, reopened.Pages.Count);
    }}
