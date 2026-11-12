using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// An open file as one growing byte buffer. Each <see cref="Commit"/> appends the document's
/// changes as an incremental update; <see cref="Undo"/> moves the end back to the previous one and
/// <see cref="Redo"/> forward again, so the buffer is always a complete PDF. History reaches back
/// to the file as it was opened, no further. After every commit, undo and redo
/// <see cref="Document"/> is a new instance on the new bytes: hold no pages or objects across one.
/// Not safe to share between threads.
/// </summary>
public sealed class PdfEditSession
{
    private static readonly long FileLimit = Array.MaxLength;

    private readonly string? _password;
    private readonly X509Certificate2? _certificate;
    private readonly List<(int End, string Label)> _steps = [];
    private byte[] _current;
    // The bytes at the newest step; after an undo, longer than _current. The same array when nothing is undone.
    private byte[] _longest;
    private int _floor;
    private int _position;
    private int _savedPosition;
    // Settable so a test need not build a file of 2 GB.
    internal long MaxBytes = FileLimit;

    private PdfEditSession(byte[] bytes, string? password, X509Certificate2? certificate = null)
    {
        _password = password;
        _certificate = certificate;
        Document = Read(bytes);
        _current = _longest = SourceBytes(Document);
        _floor = _current.Length;
        Versions = PdfVersion.Find(Document);
    }

    public static PdfEditSession Open(byte[] bytes, string? password = null) => new(bytes, password);

    public static PdfEditSession Open(string path, string? password = null) => new(ReadFile(path), password);

    /// <summary>A file encrypted for recipients, opened (and read back after every save) with the private key of <paramref name="certificate"/>.</summary>
    public static PdfEditSession Open(byte[] bytes, X509Certificate2 certificate) => new(bytes, null, certificate);

    public static PdfEditSession Open(string path, X509Certificate2 certificate) => new(ReadFile(path), null, certificate);

    private static byte[] ReadFile(string path)
    {
        if (new FileInfo(path).Length > FileLimit) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is too large.");
        return File.ReadAllBytes(path);
    }

    private PdfDocument Read(byte[] bytes) => _certificate is null ? PdfDocument.Open(bytes, _password) : PdfDocument.Open(bytes, _certificate);

    /// <summary>The document at the current state, to read and to change. Changes wait here until <see cref="Commit"/>.</summary>
    public PdfDocument Document { get; private set; }

    /// <summary>
    /// The bytes of the file at the current state, for the renderer. Committed changes only, and
    /// the array is never changed in place: each commit, undo or redo brings a new one.
    /// </summary>
    public ReadOnlyMemory<byte> Current => _current;

    /// <summary>The states the file was opened with, oldest first. Fixed at open, and again after <see cref="SaveCompact"/>.</summary>
    public IReadOnlyList<PdfVersion> Versions { get; private set; }

    public bool CanUndo => _position > 0;
    public bool CanRedo => _position < _steps.Count;
    public string? UndoLabel => CanUndo ? _steps[_position - 1].Label : null;
    public string? RedoLabel => CanRedo ? _steps[_position].Label : null;

    /// <summary>The state differs from the one last saved or opened: bytes were added or taken back, or changes wait in <see cref="Document"/>.</summary>
    public bool IsDirty => _position != _savedPosition || Document.HasChanges;

    /// <summary>
    /// Appends what changed in <see cref="Document"/> as one undoable step called
    /// <paramref name="label"/>, dropping what could be redone. False, and nothing added, when
    /// nothing changed. With <paramref name="mergeWithPrevious"/> the step joins the one before it, so
    /// the two undo together, unless that step was saved or has another label; then it is a step of its own.
    /// </summary>
    public bool Commit(string label, bool mergeWithPrevious = false)
    {
        byte[] update = PdfUpdate.Build(Document);
        if (update.Length == 0) return false;
        if ((long)_current.Length + update.Length > MaxBytes) throw TooLarge();
        byte[] next = new byte[_current.Length + update.Length];
        _current.CopyTo(next, 0);
        update.CopyTo(next, _current.Length);
        return Take(label, next, mergeWithPrevious);
    }

    /// <summary>
    /// Commits a file the caller built on the current bytes, which must be its start (a signed update, whose
    /// bytes depend on where they land). Read back and recorded like <see cref="Commit"/>.
    /// </summary>
    internal bool CommitBytes(string label, byte[] next)
    {
        if (next.Length <= _current.Length || !next.AsSpan(0, _current.Length).SequenceEqual(_current)) throw new ArgumentException("The file does not continue the current one.", nameof(next));
        if (next.Length > MaxBytes) throw TooLarge();
        return Take(label, next);
    }

    private static PdfReadException TooLarge() => new(PdfReadProblem.Unsupported, "The file is too large to change further.");

    private bool Take(string label, byte[] next, bool merge = false)
    {
        // Reading it back is the check that the update is one a strict parser takes: one that needs a rebuild is not.
        var document = Read(next);
        if (document.XrefRebuilt && !Document.XrefRebuilt) throw PdfReadException.Damaged("The update does not read back.");

        merge = merge && _position > 0 && _position != _savedPosition && _steps[_position - 1].Label == label;
        if (_savedPosition > _position) _savedPosition = -1;
        _steps.RemoveRange(_position, _steps.Count - _position);
        if (merge) _steps[^1] = (next.Length, label);
        else _steps.Add((next.Length, label));
        _position = _steps.Count;
        _current = _longest = next;
        Document = document;
        return true;
    }

    /// <summary>Drops the changes waiting in <see cref="Document"/> by reading the current bytes again.</summary>
    public void Discard() => MoveTo(_position);

    /// <summary>Back one step, dropping uncommitted changes. False when there is nothing to undo.</summary>
    public bool Undo() => CanUndo && MoveTo(_position - 1);

    /// <summary>Forward one step, dropping uncommitted changes as <see cref="Undo"/> does. False when there is nothing to redo.</summary>
    public bool Redo() => CanRedo && MoveTo(_position + 1);

    /// <summary>
    /// Writes the file as it stands, history included, by <see cref="PdfFileSaver"/>. Changes
    /// waiting in <see cref="Document"/> are committed first as a step with an empty label.
    /// </summary>
    public void Save(string path)
    {
        Commit("");
        PdfFileSaver.Save(path, _current, _password, _certificate, Document, samePages: true);
        _savedPosition = _position;
    }

    /// <summary>
    /// Writes a rewrite of the document (<see cref="PdfDocument.SaveRewrite"/>, object streams
    /// unless the file is PDF/A-1, encryption kept) without the history, and goes on from that file:
    /// undo history and <see cref="Versions"/> start again. A signature does not survive it.
    /// </summary>
    public void SaveCompact(string path)
    {
        byte[] bytes = Document.SaveRewrite(new PdfSaveOptions(Document.PdfAPart != 1, Document.Security));
        PdfFileSaver.Save(path, bytes, _password, _certificate, Document, samePages: true);
        var document = Read(bytes);
        _steps.Clear();
        _position = _savedPosition = 0;
        _current = _longest = SourceBytes(document);
        _floor = _current.Length;
        Document = document;
        Versions = PdfVersion.Find(document);
    }

    /// <summary>The file as it was at <paramref name="version"/>.</summary>
    public byte[] ExtractVersion(PdfVersion version) => _current.AsSpan(0, version.End).ToArray();

    /// <summary>Writes an earlier state of the file to <paramref name="path"/> (not the open file's own path unless the earlier state is wanted back).</summary>
    public void SaveVersion(PdfVersion version, string path) => PdfFileSaver.Save(path, ExtractVersion(version), _password, _certificate, Document, samePages: false);

    private bool MoveTo(int position)
    {
        int end = position == 0 ? _floor : _steps[position - 1].End;
        byte[] bytes = end == _longest.Length ? _longest : _longest[..end];
        Document = Read(bytes);
        _current = bytes;
        _position = position;
        return true;
    }

    private static byte[] SourceBytes(PdfDocument document) =>
        MemoryMarshal.TryGetArray(document.Source, out var segment) && segment.Offset == 0 && segment.Count == segment.Array!.Length
            ? segment.Array
            : document.Source.ToArray();
}
