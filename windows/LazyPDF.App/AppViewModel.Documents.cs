// Opening, saving and closing documents: the dialog-free half of what the File menu does, the password and
// certificate questions, undo and redo, and noticing that a file changed on disk.

using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Forms;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App;

/// <summary>What the password overlay shows: which file, whether it wants a certificate, and why the last try failed.</summary>
public sealed record OpenRequest(string Name, bool NeedsCertificate, int Attempts, string? Problem, IReadOnlyList<CertificateChoice> Certificates);

/// <summary>A file being opened that has taken long enough to show; a null fraction means the bytes are read and the engine is parsing.</summary>
public sealed record OpeningState(string Name, double? Fraction);

public sealed partial class AppViewModel
{
    /// <param name="recovery">The recovery entry the bytes came from; it stays until a tab holds them.</param>
    /// <param name="replacing">The tab this open takes the place of: a reload.</param>
    /// <param name="quiet">A reload nobody asked for: it shows no problem and no password question, and is dropped if the tab has something to lose by then.</param>
    private sealed class PendingOpen(OpenSource source, Guid? recovery = null, DocumentTab? replacing = null, bool quiet = false)
    {
        public OpenSource Source { get; } = source;
        public Guid? Recovery { get; } = recovery;
        public DocumentTab? Replacing { get; } = replacing;
        public bool Quiet { get; } = quiet;
        public int Revision { get; init; }
        public bool NeedsCertificate { get; set; }
        public IReadOnlyList<CertificateChoice> Certificates { get; set; } = [];
        public int Attempts { get; set; }
        public string? Problem { get; set; }
        public bool Submitting { get; set; }
        public bool Cancelled { get; set; }
    }

    private readonly List<PendingOpen> _pending = [];
    private readonly List<CancellationTokenSource> _reads = [];
    private readonly List<PendingOpen> _parsing = [];
    private readonly HashSet<string> _opening = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<DocumentTab, DiskStamp?> _warnedAboutDisk = [];
    private readonly HashSet<DocumentTab> _reloading = [];
    private readonly List<string> _closedFiles = [];
    private readonly List<DocumentTab> _closeQueue = [];
    private bool _exiting;

    /// <summary>The file that is waiting for a password or a certificate, if any.</summary>
    public OpenRequest? PasswordRequest => _pending.Count == 0 ? null : Describe(_pending[0]);

    /// <summary>The document that has unsaved changes and is being closed; the window asks what to do with them.</summary>
    public DocumentTab? CloseQuestion { get; private set; }

    /// <summary>The files of the tabs closed lately, the last one closed at the end.</summary>
    public IReadOnlyList<string> ClosedFiles => _closedFiles;

    public bool CanUndo => ActiveDocument?.Session.CanUndo == true;

    public bool CanRedo => ActiveDocument?.Session.CanRedo == true;

    public string? UndoLabel => ActiveDocument?.Session.UndoLabel;

    public string? RedoLabel => ActiveDocument?.Session.RedoLabel;

    public async Task OpenFilesAsync(IEnumerable<string> paths)
    {
        foreach (string path in paths) await OpenAsync(path);
    }

    /// <summary>Opens the file closed last that is still there; when none is, tries the first one anyway so the problem says why.</summary>
    public async Task ReopenClosedAsync()
    {
        while (_closedFiles.Count > 0)
        {
            string path = _closedFiles[^1];
            _closedFiles.RemoveAt(_closedFiles.Count - 1);
            if (File.Exists(path) || _closedFiles.Count == 0)
            {
                await OpenAsync(path);
                return;
            }
        }
    }

    public Task<bool> OpenNewAsync(byte[] pdf, string title) => OpenNewAsync(pdf, title, null, null);

    public Task<bool> OpenNewAsync(byte[] pdf, string title, string? password, X509Certificate2? certificate) =>
        OpenAsync(new PendingOpen(new OpenSource(pdf, null, title, Made: true)), password, certificate);

    public OpeningState? Opening { get; private set; }

    /// <summary>Stops every file that is still being read or parsed; nothing happens when none is.</summary>
    public void CancelOpening()
    {
        foreach (var read in _reads.ToList()) read.Cancel();
        if (_parsing.Count == 0) return;
        foreach (var pending in _parsing) pending.Cancelled = true;
        SetStatus(Loc.T("Canceled."));
    }

    public async Task OpenAsync(string path)
    {
        string name = System.IO.Path.GetFileName(path);
        if (TabOf(path) is { } already)
        {
            ActiveTab = already;
            return;
        }
        if (_pending.Any(p => SamePath(p.Source.Path, path)) || !_opening.Add(path)) return;
        using var reading = new CancellationTokenSource();
        _reads.Add(reading);
        OpeningState? shown = null;
        double? fraction = 0;
        bool finished = false;
        var progress = new Progress<double>(f =>
        {
            fraction = f;
            if (shown is null || finished) return;
            shown = Opening = new OpeningState(name, f);
            NotifyAll();
        });
        _ = ShowLater();
        async Task ShowLater()
        {
            await Task.Delay(300);
            if (finished) return;
            shown = Opening = new OpeningState(name, fraction);
            NotifyAll();
        }
        PendingOpen? pending = null;
        try
        {
            OpenSource source;
            try
            {
                source = await Task.Run(() => _opener.ReadAsync(path, progress, reading.Token));
            }
            catch (OperationCanceledException)
            {
                SetStatus(Loc.T("Canceled."));
                return;
            }
            catch (Exception e)
            {
                System.Diagnostics.Trace.TraceError(e.ToString());
                ShowProblem(Problems.Open(e, name));
                if (e is FileNotFoundException or DirectoryNotFoundException)
                {
                    _recentFiles.Remove(path);
                    Recent = BuildRecent();
                    NotifyAll();
                }
                return;
            }
            if (reading.IsCancellationRequested)
            {
                SetStatus(Loc.T("Canceled."));
                return;
            }
            if (source.FileId is not null && Documents.FirstOrDefault(d => d.FileId == source.FileId) is { } same)
            {
                if (same.Path is { } old && !File.Exists(old))
                {
                    same.MoveTo(path, source.Stamp, source.Hash);
                    _recentFiles.Remove(old);
                    _recentFiles.Add(path);
                    JumpLists.Note(path);
                    Recent = BuildRecent();
                    ActiveTab = same;
                    ShowNotice(Loc.T("File moved"), Loc.T("{0} was moved. This tab now follows it.", same.Title));
                    return;
                }
                ActiveTab = same;
                return;
            }
            if (source.FileId is not null && _pending.Any(p => p.Source.FileId == source.FileId)) return;
            fraction = null;
            if (shown is not null)
            {
                shown = Opening = new OpeningState(name, null);
                NotifyAll();
            }
            pending = new PendingOpen(source);
            _parsing.Add(pending);
            await OpenAsync(pending, password: null, certificate: null);
        }
        finally
        {
            finished = true;
            _opening.Remove(path);
            _reads.Remove(reading);
            if (pending is not null) _parsing.Remove(pending);
            if (shown is not null && ReferenceEquals(Opening, shown))
            {
                Opening = null;
                NotifyAll();
            }
        }
    }

    private DocumentTab? TabOf(string path) => Documents.FirstOrDefault(d => SamePath(d.Path, path));

    private static bool SamePath(string? a, string? b) => a is not null && b is not null && string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    public async Task SubmitPasswordAsync(string password)
    {
        if (_pending.Count > 0) await OpenAsync(_pending[0], password, certificate: null);
    }

    public async Task SubmitCertificateAsync(CertificateChoice choice)
    {
        if (_pending.Count > 0) await OpenAsync(_pending[0], password: null, choice.Certificate);
    }

    /// <summary>Gives up on the file that asked for a password or a certificate. A recovery copy it came from is kept.</summary>
    public void CancelPending()
    {
        if (_pending.Count == 0) return;
        _pending[0].Cancelled = true;
        _pending.RemoveAt(0);
        NotifyAll();
    }

    // True when a tab was opened, or the file waits for its password or certificate; false when it failed or was given up on.
    private async Task<bool> OpenAsync(PendingOpen pending, string? password, X509Certificate2? certificate)
    {
        if (pending.Submitting) return false;
        pending.Submitting = true;
        try
        {
            return await OpenCoreAsync(pending, password, certificate);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // OpenCoreAsync has already said what it knows; this is what it did not expect.
            _pending.Remove(pending);
            System.Diagnostics.Trace.TraceError(e.ToString());
            if (!pending.Quiet) ShowProblem(Problems.Open(e, pending.Source.Title));
            NotifyAll();
            return false;
        }
        finally
        {
            pending.Submitting = false;
        }
    }

    private async Task<bool> OpenCoreAsync(PendingOpen pending, string? password, X509Certificate2? certificate)
    {
        var source = pending.Source;
        PdfEditSession session;
        try
        {
            session = await Task.Run(() => certificate is null ? PdfEditSession.Open(source.Bytes, password) : PdfEditSession.Open(source.Bytes, certificate));
        }
        catch (PdfReadException e) when (e.Problem is PdfReadProblem.PasswordRequired or PdfReadProblem.CertificateRequired)
        {
            if (pending.Cancelled || pending.Quiet) return false;
            bool asked = _pending.Contains(pending);
            if (!asked) _pending.Add(pending);
            pending.NeedsCertificate = e.Problem == PdfReadProblem.CertificateRequired;
            pending.Certificates = pending.NeedsCertificate ? ReadCertificates() : [];
            pending.Problem = asked ? (pending.NeedsCertificate ? Loc.T("That certificate does not open this file.") : Loc.T("That password is not right.")) : null;
            if (asked) pending.Attempts++;
            NotifyAll();
            return true;
        }
        catch (PdfReadException e)
        {
            _pending.Remove(pending);
            if (!pending.Quiet) ShowProblem(Problems.Open(e, source.Title));
            return false;
        }

        if (pending.Cancelled) return false;
        _pending.Remove(pending);
        if (session.Document.Pages.Count == 0)
        {
            if (!pending.Quiet) ShowProblem(new Problem(Loc.T("Nothing to show"), Loc.T("{0} has no pages.", source.Title)));
            return false;
        }
        string? path = source.Path;
        var tab = await Task.Run(() => new DocumentTab(session, _renderers(), path, source.Title, password, _recovery,
                                                        unsaved: source.Made || pending.Recovery is not null, source.Stamp, certificate, source.Hash));
        if (pending.Cancelled)
        {
            tab.Dispose();
            return false;
        }
        if (pending.Recovery is null) tab.FileId = source.FileId;
        int at = -1;
        bool wasActive = false;
        if (pending.Replacing is { } old)
        {
            at = Strip.IndexOf(old);
            // The tab was closed, or took on work, while the file was read and parsed.
            if (at < 0 || pending.Quiet && !NothingToLose(old, pending.Revision))
            {
                tab.Dispose();
                return false;
            }
            wasActive = ReferenceEquals(_activeTab, old);
        }
        tab.Changed += Tab_Changed;
        if (at >= 0) Replace(at, tab);
        else Strip.Add(tab);
        if (pending.Recovery is { } entry) await Task.Run(() => _recovery.Delete(entry));
        if (path is not null && pending.Recovery is null && pending.Replacing is null)
        {
            _recentFiles.Add(path);
            JumpLists.Note(path);
            Recent = BuildRecent();
        }
        if (pending.Replacing is { } was)
        {
            tab.PageIndex = Math.Min(was.PageIndex, tab.PageCount - 1);
            tab.Zoom = was.Zoom;
            tab.Fit = was.Fit;
            tab.Rotation = was.Rotation;
        }
        else if (path is not null && pending.Recovery is null
                 && _recentFiles.Load().FirstOrDefault(f => string.Equals(f.Path, Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) is { } seen)
        {
            tab.PageIndex = Math.Clamp(seen.Page, 0, tab.PageCount - 1);
            tab.Zoom = seen.Zoom;
            tab.Fit = Enum.IsDefined((FitMode)seen.Fit) ? (FitMode)seen.Fit : FitMode.Width;
        }
        tab.ReadOnly = source.ReadOnly;
        if (pending.Replacing is null || wasActive) ActiveTab = tab;
        if (source.Note is not null) ShowNotice(Loc.T("Opened with changes"), source.Note);
        else if (tab.ReadOnly) ShowNotice(Loc.T("File is read-only"), Loc.T("{0} is read-only. You can work on it, but save your changes with Save as.", tab.Title));
        else if (!tab.CanDraw) ShowNotice(Loc.T("Pages cannot be shown"), Loc.T("{0} opens for editing, but Windows cannot draw its pages.", tab.Title));
        else if (pending.Replacing is null && FormEdits.OpenNotice(tab.Document, tab.Title) is var (formTitle, formText)) ShowNotice(formTitle, formText);
        return true;
    }

    private OpenRequest Describe(PendingOpen pending) => new(
        pending.Source.Title, pending.NeedsCertificate, pending.Attempts, pending.Problem, pending.Certificates);

    private static IReadOnlyList<CertificateChoice> ReadCertificates()
    {
        try
        {
            return WindowsCertificates.WithPrivateKey();
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            return [];
        }
    }

    // The tab takes the old one's place in the strip and, if the old one was in view, in the window.
    private void Replace(int index, DocumentTab tab)
    {
        var old = (DocumentTab)Strip[index];
        Strip[index] = tab;
        if (ReferenceEquals(_lastDocument, old)) _lastDocument = tab;
        old.Changed -= Tab_Changed;
        _warnedAboutDisk.Remove(old);
        old.Dispose();
    }

    private void Tab_Changed(object? sender, EventArgs e) => NotifyAll();

    /// <summary>True when <paramref name="tab"/> was made from pictures or text, has no file yet, or was read from a read-only file, so saving needs a name.</summary>
    public static bool NeedsName(DocumentTab tab) => tab.Path is null || tab.ReadOnly;

    /// <summary>Saves over the file the tab was read from. Call <see cref="NeedsName"/> first; false also when the save failed and the info bar says why.</summary>
    public bool Save(DocumentTab tab, bool closeAfter = false)
    {
        if (tab.Path is null) return false;
        if (tab.ChangedOnDisk && File.Exists(tab.Path))
        {
            // So a disk check still running does not replace this notice with its own.
            _warnedAboutDisk[tab] = tab.OnDisk;
            ShowNotice(Loc.T("File changed"), Loc.T("{0} was changed by another program. Saving now replaces that version with yours.", tab.Title),
                new NoticeAction(Loc.T("Save anyway"), () =>
                {
                    if (!Write(tab, tab.Save) || !closeAfter) return;
                    // The close question already named the marks; they count again if the window leaves the tab open.
                    int marks = tab.PendingMarks;
                    tab.PendingMarks = 0;
                    CloseRequested?.Invoke(this, tab);
                    if (Strip.Contains(tab)) tab.PendingMarks = marks;
                }));
            return false;
        }
        return Write(tab, tab.Save);
    }

    public bool SaveAs(DocumentTab tab, string path) => !OpenElsewhere(tab, path) && Write(tab, () => tab.SaveAs(path));

    public bool SaveCopy(DocumentTab tab, string path)
    {
        if (SamePath(tab.Path, path))
        {
            ShowProblem(new Problem(Loc.T("File is open"), Loc.T("{0} is the file this copy would replace. Pick another name.", tab.Title)));
            return false;
        }
        if (Replaced(tab) || OpenElsewhere(tab, path)) return false;
        try
        {
            tab.SaveCopy(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
        {
            ShowProblem(Problems.Save(e, tab.Title));
            return false;
        }
        SetStatus(Loc.T("Saved a copy of {0}.", tab.Title));
        return true;
    }

    public bool SaveCompact(DocumentTab tab, string path)
    {
        if (OpenElsewhere(tab, path) || !Write(tab, () => tab.SaveCompact(path))) return false;
        ShowNotice(Loc.T("Saved compact"), Loc.T("{0} was saved without its history, so the earlier steps can no longer be undone.", tab.Title));
        return true;
    }

    // Two tabs on one file would each save over the other.
    private bool OpenElsewhere(DocumentTab tab, string path)
    {
        if (TabOf(path) is not { } other || ReferenceEquals(other, tab)) return false;
        ShowProblem(new Problem(Loc.T("File is open"), Loc.T("{0} is open in another tab. Close that tab first, or pick another name.", other.Title)));
        return true;
    }

    /// <summary>Why the last write failed, null after one that worked.</summary>
    public Exception? LastSaveError { get; private set; }

    // A reload that finished while a dialog was open has put a new tab in place of this one; its file is not the one the user saw.
    private bool Replaced(DocumentTab tab)
    {
        if (Strip.Contains(tab)) return false;
        ShowNotice(Loc.T("File reloaded"), Loc.T("{0} was reloaded from disk while you were choosing a name, so nothing was saved. Try again.", tab.Title));
        return true;
    }

    private bool Write(DocumentTab tab, Action save)
    {
        if (Replaced(tab)) return false;
        try
        {
            save();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
        {
            LastSaveError = e;
            ShowProblem(Problems.Save(e, tab.Title));
            return false;
        }
        LastSaveError = null;
        _warnedAboutDisk.Remove(tab);
        if (tab.Path is { } path)
        {
            // A save puts a new file in place, so the index read at open no longer matches.
            tab.FileId = DocumentOpener.Identity(path);
            _recentFiles.Add(path);
            JumpLists.Note(path);
            _recentFiles.RememberView(path, tab.PageIndex, tab.Zoom, (int)tab.Fit);
        }
        Recent = BuildRecent();
        _message = null;
        SetStatus(Loc.T("Saved {0}.", tab.Title));
        return true;
    }

    public void Undo()
    {
        if (ActiveDocument is { } tab && tab.Undo())
        {
            if (_message is { IsError: false }) _message = null;
            NotifyAll();
        }
    }

    public void Redo()
    {
        if (ActiveDocument is { } tab && tab.Redo())
        {
            if (_message is { IsError: false }) _message = null;
            NotifyAll();
        }
    }

    /// <summary>Closes the tab if it has nothing unsaved and no redaction marks waiting; otherwise sets <see cref="CloseQuestion"/> and returns false.</summary>
    public bool RequestClose(DocumentTab tab)
    {
        if (WaitForJob()) return false;
        DropAction();
        if (!tab.IsDirty && !tab.HasUnappliedWork)
        {
            Close(tab);
            return true;
        }
        ActiveTab = tab;
        CloseQuestion = tab;
        NotifyAll();
        return false;
    }

    /// <summary>Closes the tab and lets go of what it holds. Whatever was unsaved is lost.</summary>
    public void Close(DocumentTab tab)
    {
        int index = Strip.IndexOf(tab);
        if (index < 0) return;
        bool wasActive = ReferenceEquals(_activeTab, tab);
        Strip.RemoveAt(index);
        if (wasActive) _activeTab = Strip[Math.Min(index, Strip.Count - 1)];
        if (ReferenceEquals(_lastDocument, tab)) _lastDocument = Documents.LastOrDefault();
        if (ReferenceEquals(CloseQuestion, tab)) CloseQuestion = null;
        DropAction();
        _warnedAboutDisk.Remove(tab);
        tab.Changed -= Tab_Changed;
        RememberView(tab);
        if (tab.Path is { } path)
        {
            _closedFiles.Remove(path);
            _closedFiles.Add(path);
            if (_closedFiles.Count > 10) _closedFiles.RemoveAt(0);
        }
        tab.Dispose();
        NotifyAll();
        if (_exiting) ContinueExit(raise: true);
        else if (CloseQuestion is null) ContinueClosing();
    }

    /// <summary>Closes the tabs that have nothing unsaved at once and asks about the first one that has; each answer carries on with the rest.</summary>
    public void RequestCloseMany(IEnumerable<DocumentTab> tabs)
    {
        if (WaitForJob()) return;
        DropAction();
        _closeQueue.Clear();
        _closeQueue.AddRange(tabs);
        ContinueClosing();
    }

    private void ContinueClosing()
    {
        // Close() carries on with the queue itself, so a question set inside it ends this loop.
        while (_closeQueue.Count > 0 && CloseQuestion is null)
        {
            var tab = _closeQueue[0];
            _closeQueue.RemoveAt(0);
            if (!Strip.Contains(tab)) continue;
            if (tab.IsDirty || tab.HasUnappliedWork)
            {
                ActiveTab = tab;
                CloseQuestion = tab;
                NotifyAll();
                return;
            }
            Close(tab);
        }
    }

    public bool IsExiting => _exiting;

    public int Unsettled => Documents.Count(d => d.IsDirty || d.HasUnappliedWork);

    /// <summary>Closes every document with changes, marks and measurements included; with an exit under way the last one carries it on.</summary>
    public void DiscardAll()
    {
        foreach (var tab in Documents.Where(d => d.IsDirty || d.HasUnappliedWork).ToList()) Close(tab);
    }

    /// <summary>The answer to <see cref="CloseQuestion"/> that keeps the document open.</summary>
    public void CancelClose()
    {
        CloseQuestion = null;
        _closeQueue.Clear();
        _exiting = false;
        NotifyAll();
    }

    /// <summary>Moves a document tab to <paramref name="index"/> in the strip; the Home tab stays first.</summary>
    public void MoveTab(DocumentTab tab, int index)
    {
        int from = Strip.IndexOf(tab);
        index = Math.Clamp(index, 1, Strip.Count - 1);
        if (from < 1 || from == index) return;
        Strip.Move(from, index);
        NotifyAll();
    }

    /// <summary>True when the window can close now; otherwise asks about the first document with unsaved changes and goes on from there.</summary>
    public bool RequestExit()
    {
        if (WaitForJob()) return false;
        DropAction();
        _exiting = true;
        return !ContinueExit(raise: false);
    }

    // A job edits the document off the thread, so what is in it now is not something to save or to throw away.
    private bool WaitForJob()
    {
        if (!IsBusy) return false;
        ShowNotice(Loc.T("Still working"), Loc.T("Wait for the job to end, or cancel it, then close."));
        return true;
    }

    private void RememberView(DocumentTab tab)
    {
        if (tab.Path is { } path && tab.PageCount > 1) _recentFiles.RememberView(path, tab.PageIndex, tab.Zoom, (int)tab.Fit);
    }

    private bool ContinueExit(bool raise)
    {
        if (Documents.FirstOrDefault(d => d.IsDirty || d.HasUnappliedWork) is { } dirty)
        {
            ActiveTab = dirty;
            CloseQuestion = dirty;
            NotifyAll();
            return true;
        }
        foreach (var tab in Documents.ToList())
        {
            RememberView(tab);
            tab.Dispose();
        }
        _exiting = false;
        if (raise) RaiseExit();
        return false;
    }

    /// <summary>
    /// Looks at the active document's file: when another program changed or removed it, the info bar says so
    /// (once for each state the file is found in). Called when the window comes forward and when a tab is picked.
    /// </summary>
    public async Task CheckDiskAsync()
    {
        if (ActiveDocument is not { Path: { } path } tab) return;
        var known = tab.Known;
        _warnedAboutDisk.TryGetValue(tab, out var seen);
        DiskStamp? found;
        bool touched;
        try
        {
            (found, touched) = await Task.Run(() =>
            {
                DiskStamp? now;
                try
                {
                    File.GetAttributes(path);
                    now = DiskStamp.Of(path);
                }
                catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
                {
                    now = null;
                }
                return (now, now is not null && now != seen && tab.IsChangedFrom(now) && tab.IsOnlyTouched(now));
            });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
        // A save made while the file was being looked at changes both.
        if (tab.Path != path || tab.Known != known) return;
        if (!ReferenceEquals(ActiveDocument, tab) || !Strip.Contains(tab) || !tab.IsChangedFrom(found)) return;
        if (touched)
        {
            tab.AcceptDiskState(found);
            return;
        }
        // Nothing to lose: take the new version without asking. A tool open may write the file itself and reload.
        if (found is not null && _reloading.Contains(tab)) return;
        if (found is not null && found != seen && NothingToLose(tab, tab.Revision)
            && await TryReloadAsync(tab, quiet: true))
        {
            SetStatus(Loc.T("Reloaded {0}.", tab.Title));
            return;
        }
        if (_warnedAboutDisk.TryGetValue(tab, out seen) && seen == found) return;
        _warnedAboutDisk[tab] = found;
        if (found is null)
        {
            ShowNotice(Loc.T("File is gone"), Loc.T("{0} was moved or deleted. Save it again to keep your work.", tab.Title));
            return;
        }
        string text = tab.IsDirty
            ? Loc.T("{0} was changed by another program. Opening that version drops your unsaved changes.", tab.Title)
            : tab.HasUnappliedWork
            ? Loc.T("{0} was changed by another program. Opening that version drops the marks, measurements and typed text not applied yet.", tab.Title)
            : Loc.T("{0} was changed by another program.", tab.Title);
        ShowNotice(Loc.T("File changed"), text, new NoticeAction(Loc.T("Open that version"), () => _ = ReloadAsync(tab)));
    }

    public Task ReloadAsync(DocumentTab tab) => TryReloadAsync(tab);

    private bool NothingToLose(DocumentTab tab, int revision) =>
        !tab.IsDirty && !tab.HasUnappliedWork && tab.Revision == revision && _activeToolId is null && !IsBusy;

    /// <summary>Reads the file again from disk and, once that worked, puts it in the place of the tab, keeping its page and zoom; unsaved changes are dropped then, not before. False when the tab was not replaced. Quiet shows nothing when the read fails, as the other program may still be writing.</summary>
    public Task<bool> TryReloadAsync(DocumentTab tab) => TryReloadAsync(tab, quiet: false);

    private async Task<bool> TryReloadAsync(DocumentTab tab, bool quiet)
    {
        if (tab.Path is not { } path || !Strip.Contains(tab) || !_reloading.Add(tab)) return false;
        try
        {
            int revision = tab.Revision;
            OpenSource source;
            try
            {
                source = await Task.Run(() => _opener.Read(path));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
            {
                if (!quiet) ShowProblem(Problems.Open(e, tab.Title));
                return false;
            }
            if (!Strip.Contains(tab)) return false;
            bool opened = await OpenAsync(new PendingOpen(source, replacing: tab, quiet: quiet) { Revision = revision }, tab.Password, tab.Certificate);
            return opened && !Strip.Contains(tab);
        }
        finally
        {
            _reloading.Remove(tab);
        }
    }
}
