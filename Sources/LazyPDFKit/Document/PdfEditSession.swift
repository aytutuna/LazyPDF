import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfEditSession.cs: an open file as one growing byte buffer. Each `commit`
// appends the document's changes as an incremental update; `undo` moves the end back to the previous one and
// `redo` forward again, so the buffer is always a complete PDF. History reaches back to the file as it was
// opened, no further. After every commit, undo and redo `document` is a new instance on the new bytes: hold no
// pages or objects across one. Not safe to share between threads.
//
// The C# keeps the password or the certificate and opens with whichever it has; here the session keeps the
// function that opens (`reader`), so the one code path serves both and Linux, which has no certificates, builds.

public final class PdfEditSession {
    private let reader: ([UInt8]) throws -> PdfDocument
    private var steps: [(end: Int, label: String)] = []
    private var longest: [UInt8]
    private var floor: Int
    private var position = 0
    private var savedPosition = 0

    /// The document at the current state, to read and to change. Changes wait here until `commit`.
    public private(set) var document: PdfDocument

    /// The bytes of the file at the current state, for the renderer. Committed changes only, and the array is
    /// never changed in place: each commit, undo or redo brings a new one.
    public private(set) var current: [UInt8]

    /// The states the file was opened with, oldest first. Fixed at open, and again after `saveCompact`.
    public private(set) var versions: [PdfVersion]

    private init(_ bytes: [UInt8], _ reader: @escaping ([UInt8]) throws -> PdfDocument) throws {
        self.reader = reader
        let opened = try reader(bytes)
        document = opened
        current = opened.source
        longest = opened.source
        floor = opened.source.count
        versions = PdfVersion.find(opened)
    }

    public static func open(_ bytes: [UInt8], password: String? = nil) throws -> PdfEditSession {
        try PdfEditSession(bytes) { try PdfDocument.open($0, password: password) }
    }

    public static func open(path: String, password: String? = nil) throws -> PdfEditSession {
        try open([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), password: password)
    }

    #if canImport(Security)
    /// A file encrypted for recipients, opened (and read back after every save) with the private key of `certificate`.
    public static func open(_ bytes: [UInt8], certificate: PdfCertificate) throws -> PdfEditSession {
        try PdfEditSession(bytes) { try PdfDocument.open($0, certificate: certificate) }
    }

    public static func open(path: String, certificate: PdfCertificate) throws -> PdfEditSession {
        try open([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), certificate: certificate)
    }
    #endif

    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < steps.count }
    public var undoLabel: String? { canUndo ? steps[position - 1].label : nil }
    public var redoLabel: String? { canRedo ? steps[position].label : nil }

    /// The state differs from the one last saved or opened: bytes were added or taken back, or changes wait in
    /// `document`.
    public var isDirty: Bool { position != savedPosition || document.hasChanges }

    /// Appends what changed in `document` as one undoable step called `label`, dropping what could be redone.
    /// False, and nothing added, when nothing changed.
    @discardableResult
    public func commit(_ label: String) throws -> Bool {
        let update = try PdfUpdate.build(document)
        if update.isEmpty { return false }
        return try take(label, current + update)
    }

    /// The update that makes `copy`, a document opened from `current` and then changed, into the next step; empty when nothing
    /// changed. It is built apart from the session so that a long edit can run on a copy off the main thread.
    public static func update(of copy: PdfDocument) throws -> [UInt8] {
        try PdfUpdate.build(copy)
    }

    /// Appends an update from `update(of:)`, built on a copy of the first `length` bytes, as one step called `label`. Throws
    /// when the session has moved on since, so a stale edit cannot land on a different file.
    @discardableResult
    public func commit(_ label: String, update: [UInt8], over length: Int) throws -> Bool {
        guard length == current.count else { throw InvalidOperationException("The file changed while the edit was made.") }
        if update.isEmpty { return false }
        return try take(label, current + update)
    }

    /// Commits a file the caller built on the current bytes, which must be its start (a signed update, whose
    /// bytes depend on where they land). Read back and recorded like `commit`.
    @discardableResult
    func commitBytes(_ label: String, _ next: [UInt8]) throws -> Bool {
        precondition(next.count > current.count && Array(next[0..<current.count]) == current, "The file does not continue the current one.")
        return try take(label, next)
    }

    private func take(_ label: String, _ next: [UInt8]) throws -> Bool {
        // Reading it back is the check that the update is one a strict parser takes: one that needs a rebuild is not.
        let reopened = try reader(next)
        if reopened.xrefRebuilt && !document.xrefRebuilt { throw PdfReadException.damaged("The update does not read back.") }

        if savedPosition > position { savedPosition = -1 }
        steps.removeSubrange(position..<steps.count)
        steps.append((next.count, label))
        position = steps.count
        current = next
        longest = next
        document = reopened
        return true
    }

    /// Drops the changes waiting in `document` by reading the current bytes again.
    public func discard() throws {
        _ = try moveTo(position)
    }

    /// Back one step, dropping uncommitted changes. False when there is nothing to undo.
    @discardableResult
    public func undo() throws -> Bool {
        try canUndo && moveTo(position - 1)
    }

    /// Forward one step, dropping uncommitted changes as `undo` does. False when there is nothing to redo.
    @discardableResult
    public func redo() throws -> Bool {
        try canRedo && moveTo(position + 1)
    }

    /// Writes the file as it stands, history included, by `PdfFileSaver`. Changes waiting in `document` are
    /// committed first as a step with an empty label.
    public func save(_ path: String) throws {
        try commit("")
        try PdfFileSaver.save(path, current, source: document, samePages: true, open: reader)
        savedPosition = position
    }

    /// Writes a rewrite of the document (`PdfDocument.saveRewrite`, object streams unless the file is PDF/A-1,
    /// encryption kept) without the history, and goes on from that file: undo history and `versions` start
    /// again. A signature does not survive it.
    public func saveCompact(_ path: String) throws {
        let bytes = try document.saveRewrite(PdfSaveOptions(useObjectStreams: document.pdfAPart != 1, security: document.security))
        try PdfFileSaver.save(path, bytes, source: document, samePages: true, open: reader)
        let reopened = try reader(bytes)
        steps.removeAll()
        position = 0
        savedPosition = 0
        current = reopened.source
        longest = reopened.source
        floor = reopened.source.count
        document = reopened
        versions = PdfVersion.find(reopened)
    }

    /// The file as it was at `version`.
    public func extractVersion(_ version: PdfVersion) -> [UInt8] {
        precondition(version.end >= 0 && version.end <= current.count, "version")
        return Array(current[0..<version.end])
    }

    /// Writes an earlier state of the file to `path` (not the open file's own path unless the earlier state is wanted back).
    public func saveVersion(_ version: PdfVersion, _ path: String) throws {
        try PdfFileSaver.save(path, extractVersion(version), source: document, samePages: false, open: reader)
    }

    private func moveTo(_ target: Int) throws -> Bool {
        let end = target == 0 ? floor : steps[target - 1].end
        let bytes = end == longest.count ? longest : Array(longest[0..<end])
        document = try reader(bytes)
        current = bytes
        position = target
        return true
    }
}
