import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.cs: reader after Lazy Scan's PdfReaderLite.cs, its
// cross-reference tables, cross-reference streams, hybrid files, object streams and limits, with the refusals
// turned into repairs (PdfDocument.Repair.swift) and the page tree, security and editing added around them.
//
// The C# class is partial; the parts are extensions in this folder. Swift keeps stored properties in the type's
// own declaration, so the state of every part is listed here, internal instead of private. The C# `Dispose` has
// no twin: the caches go when the document does.

/// An open PDF: the object table, the trailer and catalog, the pages and the facts about the file.
/// Objects load on first use and are cached, so the same object is always the same instance and
/// a change made to it stays. The reader repairs what it can (`repairs`); what it
/// cannot is a `PdfReadException`. Not safe to share between threads.
public final class PdfDocument {
    /// The highest object number a PDF may use (ISO 32000-1 Annex C).
    static let maxObjectNumber = 8_388_607

    private static let maxRepairs = 100

    // Core
    var source: [UInt8]
    var sourceBytes: PdfArrayBytes
    var password: String?
    var headerVersionEnd = 0
    var hadInfo = false
    /// How many attachments a page assembly left out of this document because they would not decode or were over the size limit.
    public internal(set) var skippedAttachments = 0

    // Cross-references
    /// Where the newest cross-reference section starts, as the file said; 0 when the table was rebuilt.
    var startXref = 0
    /// The newest section is a cross-reference stream, so an update writes one too.
    var xrefIsStream = false
    /// The first object number not used: the trailer's /Size, or one past the highest listed when that is more.
    var nextObjectNumber = 0
    /// The table was rebuilt from a scan, so the offsets in the file's own cross-reference data cannot be built on.
    var xrefRebuilt = false
    var entries: [Int: Entry] = [:]
    /// The numbers of `entries` in the order the file listed them (the order the C# Dictionary enumerates), for walks that must match it.
    var entryOrder: [Int] = []
    var sections: [Int] = []
    var hybridStreams = Set<Int>()
    var loadingXref = false

    // Objects
    var objects: [Int: Slot] = [:]
    var objectStreams: [Int: ObjectStream] = [:]
    var loading = Set<Int>()
    var deleted = Set<Int>()
    var trailerPrint: UInt64 = 0
    var firstNew = Int.max

    // Repair
    var scanned: Scan?

    // Streams
    var lastEndstream = -2
    var lastEndobj = -2
    var lengthRepaired = Set<Int>()

    // Security
    #if canImport(Security)
    var certificate: PdfCertificate?
    #endif
    var encryptDictionary: PdfDictionary?
    var encryptNumber = 0
    var securityId: [UInt8] = []

    // Pages and facts
    var pageList: [PageNode]?
    var pagesWalked = false
    var linearizedKnown: Bool?
    var pdfAKnown: (part: Int?, conformance: String?)?

    private init(_ data: [UInt8]) {
        source = data
        sourceBytes = PdfArrayBytes(data)
    }

    public static func open(_ bytes: [UInt8], password: String? = nil) throws -> PdfDocument {
        let document = PdfDocument(bytes)
        document.password = password
        try document.load()
        return document
    }

    public static func open(path: String, password: String? = nil) throws -> PdfDocument {
        try open(read(path), password: password)
    }

    #if canImport(Security)
    /// Opens a file encrypted for recipients with the private key of `certificate`.
    /// A certificate that is not a recipient, or has no private key, is `PdfReadProblem.certificateRequired`.
    /// A file with the standard handler opens only if its user password is empty.
    public static func open(_ bytes: [UInt8], certificate: PdfCertificate) throws -> PdfDocument {
        let document = PdfDocument(bytes)
        document.certificate = certificate
        try document.load()
        return document
    }

    public static func open(path: String, certificate: PdfCertificate) throws -> PdfDocument {
        try open(read(path), certificate: certificate)
    }
    #endif

    private static func read(_ path: String) throws -> [UInt8] {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        if try file.seekToEnd() > UInt64(Int32.max) { throw PdfReadException(.unsupported, "The file is too large.") }
        try file.seek(toOffset: 0)
        return [UInt8](try file.readToEnd() ?? Data())
    }

    /// What was wrong with the file and how it was got round, one line each (at most 100).
    public internal(set) var repairs: [String] = []

    func addRepair(_ text: String) {
        if repairs.count < Self.maxRepairs {
            repairs.append(text)
        } else if repairs.count == Self.maxRepairs {
            repairs.append("More repairs were made than are listed.")
        }
    }

    /// The bytes the document was read from, starting at the header (anything before it is cut off).
    public var length: Int { source.count }

    /// The newest trailer; /Root, /Info, /ID and /Encrypt come from an older one when the newest lacks them.
    public internal(set) var trailer = PdfDictionary()

    public internal(set) var catalog = PdfDictionary()

    public var info: PdfDictionary? { dict(trailer, "Info") }

    /// The trailer's two /ID strings; empty without them.
    public var id: [[UInt8]] {
        guard let ids = array(trailer, "ID") else { return [] }
        return ids.items.compactMap { resolve($0) as? PdfString }.map { $0.bytes }
    }

    public var isEncrypted: Bool { encryptDictionary != nil }

    /// The handler that decrypts the file; nil when it is not encrypted.
    public internal(set) var security: PdfSecurity?

    /// The version of the file: the header's, or the catalog's /Version when that is newer.
    public var version: String {
        let header = headerVersion()
        if let declared = name(catalog, "Version"), let d = SystemVersion(declared), let h = SystemVersion(header), d > h {
            return declared
        }
        return header
    }

    private func headerVersion() -> String {
        let at = 5
        let end = at + Swift.min(headerVersionEnd - at, 8)
        let text = Latin1.string(Array(source[at..<Swift.max(at, Swift.min(end, source.count))]))
        return SystemVersion(text) != nil ? text : "1.4"
    }

    private func load() throws {
        try findHeader()
        var rebuilt = false
        do {
            try loadCrossReferences()
        } catch let e as PdfReadException {
            try rebuild(e.message)
            rebuilt = true
        }
        if !rebuilt {
            try openSecurity()
            if !catalogUsable() { try rebuild("The catalog could not be read.") }
        }
        firstNew = nextObjectNumber
        trailerPrint = fingerprint(trailer)
        hadInfo = trailer.containsKey("Info")
    }

    /// The header must come in the first 1024 bytes; what is before it is cut off, so offsets count from it as viewers count them.
    private func findHeader() throws {
        let head = Array(source.prefix(1024))
        guard let at = head.indexOf("%PDF-".keywordBytes) else {
            throw PdfReadException(.notPdf, "The file does not start with %PDF.")
        }
        if at > 0 {
            source = Array(source[at...])
            sourceBytes = PdfArrayBytes(source)
            addRepair("Cut \(at) bytes before the %PDF header.")
        }
        var end = 5
        while end < source.count && end < 13 && ((source[end] >= 0x30 && source[end] <= 0x39) || source[end] == 0x2E) { end += 1 }
        headerVersionEnd = end
    }

    func catalogUsable() -> Bool {
        guard let root = resolve(trailer["Root"]) as? PdfDictionary, resolve(root["Pages"]) is PdfDictionary else { return false }
        catalog = root
        return true
    }
}
