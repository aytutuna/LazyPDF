using System.ComponentModel;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Documents;

/// <summary>
/// One open document: the edit session, where it was read from, whether it has unsaved changes and the
/// renderer that draws it. Tools change <see cref="Document"/> and call <see cref="Commit"/>; the tab loads
/// the renderer again, keeps the recovery copy current and tells the window through <see cref="Changed"/>.
/// </summary>
public sealed class DocumentTab : ITab, IDisposable
{
    private readonly string? _password;
    private readonly RecoveryStore? _recovery;
    private string? _path;
    private string _title;
    private bool _unsaved;
    private DiskStamp? _disk;
    private byte[]? _diskHash;

    internal const int HashLimit = 256 * 1024 * 1024;

    /// <param name="path">Where the file lives; null for a document made from pictures or text, which has to be saved as a new file.</param>
    /// <param name="unsaved">The state differs from the file on disk although the session has no history: a document restored after a crash, or one that was just made.</param>
    /// <param name="known">What the file looked like when its bytes were read; the tab's creation time when not given.</param>
    /// <param name="certificate">The certificate the file was opened with, kept for the readers that open the bytes again.</param>
    public DocumentTab(PdfEditSession session, IDocumentRenderer renderer, string? path, string title, string? password = null, RecoveryStore? recovery = null, bool unsaved = false,
                       DiskStamp? known = null, X509Certificate2? certificate = null, byte[]? diskHash = null)
    {
        Session = session;
        Renderer = renderer;
        _path = path;
        _title = title;
        _password = password;
        _recovery = recovery;
        _unsaved = unsaved;
        Certificate = certificate;
        _disk = known ?? DiskStamp.Of(path);
        _diskHash = diskHash;
        CanDraw = renderer.Load(session, password);
        if (unsaved) WriteRecovery();
    }

    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>Which file on disk the tab was read from, however its path was spelled; null for recovery copies and made documents.</summary>
    public string? FileId { get; set; }

    public PdfEditSession Session { get; }

    public IDocumentRenderer Renderer { get; }

    /// <summary>The password the file was opened with; null when it needed none, or was opened with a certificate.</summary>
    public string? Password => _password;

    /// <summary>The certificate the file was opened with; null when it was opened any other way.</summary>
    public X509Certificate2? Certificate { get; }

    /// <summary>The document at the current state; see <see cref="PdfEditSession.Document"/>.</summary>
    public PdfDocument Document => Session.Document;

    public int PageCount => Document.Pages.Count;

    /// <summary>False when the system cannot draw the file (it can still be edited and saved).</summary>
    public bool CanDraw { get; private set; }

    /// <summary>Counts every change to the file's bytes (commit, undo, redo, save compact), so a viewer knows when to draw again.</summary>
    public int Revision { get; private set; }

    /// <summary>Counts the saves that numbered the file's objects again, after which an object number no longer names the same thing.</summary>
    public int Rewrites { get; private set; }

    /// <summary>The page the viewer shows, 0-based, kept here so each tab comes back as it was left.</summary>
    public int PageIndex { get; set; }

    /// <summary>The viewer's zoom, 1 for 100 %; 0 while the zoom follows <see cref="Fit"/> or the viewer has not chosen one.</summary>
    public double Zoom { get; set; }

    /// <summary>How the viewer's zoom follows the window; none while a zoom of its own is set.</summary>
    public LazyPDF.App.Viewer.FitMode Fit { get; set; }

    /// <summary>The file was read with the read-only attribute, so saving needs a new name; cleared once the tab has a file of its own.</summary>
    public bool ReadOnly { get; set; }

    public string? Path => _path;

    public string Title => _path is null ? _title : System.IO.Path.GetFileName(_path);

    public string AutomationName => IsDirty ? Loc.T("{0}, unsaved changes", Title) : Title;

    public string Glyph => "\uE8A5";

    public bool IsDirty => _unsaved || Session.IsDirty;

    /// <summary>Redaction marks drawn but not yet applied; they live in the Redact panel and are lost with the tab.</summary>
    public int PendingMarks { get; set; }

    public bool CanClose => true;

    /// <summary>Raised when the file's bytes changed.</summary>
    public event EventHandler? Changed;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Commits what a tool changed in <see cref="Document"/> as one undoable step. False when nothing changed.</summary>
    public bool Commit(string label)
    {
        if (!Session.Commit(label)) return false;
        Refresh();
        return true;
    }

    /// <summary>Takes up steps the session committed by itself, as a signature does: loads the renderer again and tells the window.</summary>
    public void Reload() => Refresh();

    public bool Undo() => Session.Undo() && Refreshed();

    public bool Redo() => Session.Redo() && Refreshed();

    public void Save()
    {
        if (_path is null) throw new InvalidOperationException("The document has no file yet.");
        Session.Save(_path);
        Saved();
    }

    public void SaveAs(string path)
    {
        Session.Save(path);
        _path = path;
        ReadOnly = false;
        Saved();
    }

    /// <summary>Writes the file without its history to <paramref name="path"/> and goes on from that file.</summary>
    public void SaveCompact(string path)
    {
        Session.SaveCompact(path);
        _path = path;
        ReadOnly = false;
        Saved(rewritten: true);
    }

    /// <summary>The file on disk is not the one that was read or saved: another program changed or removed it.</summary>
    public bool ChangedOnDisk => _path is not null && OnDisk != _disk;

    /// <summary>What the file looked like when it was read or last saved.</summary>
    public DiskStamp? Known => _disk;

    public bool IsChangedFrom(DiskStamp? found) => _path is not null && found != _disk;

    /// <summary>The file as it is now; null when it is gone or the tab has no file.</summary>
    public DiskStamp? OnDisk => DiskStamp.Of(_path);

    /// <summary>The file has the length that was read and the very bytes, so only its write time moved. Reads the file.</summary>
    public bool IsOnlyTouched(DiskStamp found)
    {
        if (_path is null || _diskHash is null || found.Length != _disk?.Length) return false;
        try
        {
            using var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return System.Security.Cryptography.SHA256.HashData(stream).AsSpan().SequenceEqual(_diskHash);
        }
        catch (IOException)
        {
            return false;
        }
    }

    /// <summary>Takes the file as it is now for the one that was read.</summary>
    public void AcceptDiskState() => _disk = OnDisk;

    /// <summary>Takes <paramref name="found"/>, a stamp already checked, so a write that came after it still shows.</summary>
    public void AcceptDiskState(DiskStamp? found) => _disk = found;

    private bool Refreshed()
    {
        Refresh();
        return true;
    }

    /// <summary>For a tool whose engine call committed on the session itself: draws the new state and tells the window.</summary>
    public void Refresh()
    {
        CanDraw = Renderer.Load(Session, _password);
        Revision++;
        WriteRecovery();
        Changed?.Invoke(this, EventArgs.Empty);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    // The bytes of a save are the ones already shown, so only the state of the tab changes, unless the save rewrote the file.
    private void Saved(bool rewritten = false)
    {
        _unsaved = false;
        _diskHash = null;
        AcceptDiskState();
        _recovery?.Delete(Id);
        if (rewritten)
        {
            Rewrites++;
            Refresh();
        }
        else PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    private static readonly DateTime _processStarted = System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime();

    private void WriteRecovery()
    {
        if (_recovery is null) return;
        if (!IsDirty)
        {
            _recovery.Delete(Id);
            return;
        }
        _recovery.Write(Id, Session.Current, new RecoveryMeta
        {
            Title = Title,
            OriginalPath = _path,
            Saved = DateTimeOffset.Now,
            OriginalWrite = _disk?.Write ?? default,
            OriginalLength = _disk?.Length ?? 0,
            ProcessId = Environment.ProcessId,
            ProcessStarted = _processStarted,
        });
    }

    /// <summary>Lets go of the renderer and removes the recovery copy: closing on purpose is not a crash.</summary>
    public void Dispose()
    {
        Renderer.Dispose();
        _recovery?.Delete(Id);
    }
}
