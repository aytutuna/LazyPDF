import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.cs: the outcome of a conversion and the converter. `bytes` is the new
// file, nil when the conversion was refused and `refusal` says why. `remaining` is what the validator still finds in the
// result, empty when it is clean; `changes` says in sentences what was altered.
//
// The C# class is partial; the parts are extensions in this folder. The conversion run is given the document it works on:
// the C# opens it inside Run and keeps it in a field set to null until then. A refusal that is not a PdfReadException of the
// rewrite (an ArgumentException or InvalidOperationException from the annotation and form layers, which the C# does not
// catch either) leaves `convert` as a thrown error.

public struct PdfAConversion {
    public let bytes: [UInt8]?
    public let refusal: String?
    public let remaining: [PdfAIssue]
    public let changes: [String]

    public init(_ bytes: [UInt8]?, _ refusal: String?, _ remaining: [PdfAIssue], _ changes: [String]) {
        self.bytes = bytes
        self.refusal = refusal
        self.remaining = remaining
        self.changes = changes
    }

    public var isClean: Bool { bytes != nil && remaining.isEmpty }
}

/// Takes a PDF to a PDF/A level by rewriting it. It embeds or replaces fonts from the font source, corrects widths,
/// drops encryption, actions, JavaScript and forbidden annotations, draws missing appearances, rewrites LZW, adds the
/// sRGB output intent and writes the XMP identification with /Info in step, but only when nothing remains broken: a file
/// that still fails gets the same metadata without the pdfaid claim. It refuses what it cannot do honestly
/// (transparency for part 1, an encrypted file whose permissions forbid changes, a dynamic XFA form); what it leaves
/// broken it reports in `PdfAConversion.remaining`.
public final class PdfAConverter {
    private let fonts: FontSource?

    public init(_ fonts: FontSource? = nil) {
        self.fonts = fonts
    }

    /// Converts `pdf`; `date` is the time of conversion, for ModDate and the metadata date.
    public func convert(_ pdf: [UInt8], _ level: PdfALevel, _ date: DateTimeOffset, _ password: String? = nil) throws -> PdfAConversion {
        let document: PdfDocument
        do {
            document = try PdfDocument.open(pdf, password: password)
        } catch let error as PdfReadException {
            return PdfAConversion(nil, error.problem == .passwordRequired ? PdfAText.needsPassword : PdfAText.unreadable, [], [])
        }
        return try PdfAConversionRun(document, fonts, level, date).run()
    }
}

final class PdfAConversionRun {
    let document: PdfDocument
    let fonts: FontSource?
    let level: PdfALevel
    let date: DateTimeOffset
    var changes: [String] = []
    var left: [PdfAIssue] = []
    var meta: DocumentMetadata?

    init(_ document: PdfDocument, _ fonts: FontSource?, _ level: PdfALevel, _ date: DateTimeOffset) {
        self.document = document
        self.fonts = fonts
        self.level = level
        self.date = date
    }

    var part: Int { level.part() }

    func run() throws -> PdfAConversion {
        if let security = document.security, !security.openedAsOwner, !security.permissions.contains(.modify) { return refused(PdfAText.noRights) }
        if PdfForm.read(document).xfa == .dynamic { return refused(PdfAText.dynamicXfa) }
        let before = PdfAChecker(document, level)
        before.run()
        var needed: [String] = []
        for issue in before.report().issues where issue.clause == "6.4" && issue.message != PdfAText.transparencyGroup {
            if !needed.contains(issue.message) { needed.append(issue.message) }
        }
        if part == 1 && !needed.isEmpty { return refused(PdfAText.transparency(needed)) }
        do {
            try apply(before)
            var bytes = try document.saveRewrite()
            setHeaderVersion(&bytes)
            let written = try PdfDocument.open(bytes)
            var remaining = Self.union(PdfAValidator.validate(written, level).issues, left)
            if !remaining.isEmpty {
                try putPacket(declare: false)
                if let at = changes.firstIndex(of: PdfAText.metadataWritten(level)) { changes.remove(at: at) }
                changed(PdfAText.notDeclared(level))
                bytes = try document.saveRewrite()
                setHeaderVersion(&bytes)
                // What the delivered file fails is what a validator will say of it, which includes the missing identification.
                let delivered = try PdfDocument.open(bytes)
                remaining = Self.union(PdfAValidator.validate(delivered, level).issues, left)
            }
            return PdfAConversion(bytes, nil, remaining, changes)
        } catch let error as PdfReadException {
            return refused(PdfAText.couldNotRewrite(error.message))
        }
    }

    // Enumerable.Union: each issue once, the first list's before the second's.
    private static func union(_ first: [PdfAIssue], _ second: [PdfAIssue]) -> [PdfAIssue] {
        var seen = Set<PdfAIssue>()
        return (first + second).filter { seen.insert($0).inserted }
    }

    private func refused(_ reason: String) -> PdfAConversion { PdfAConversion(nil, reason, [], changes) }

    private func apply(_ before: PdfAChecker) throws {
        if document.isEncrypted { changed(PdfAText.encryptionRemoved) }
        if document.isSigned { changed(PdfAText.signaturesBroken) }
        let parts = collect()
        removeActions(parts)
        clampIntegers(parts)
        if part == 1 { removeGroups(parts) }
        try fixAnnotations()
        try fixForm()
        fixStreams(parts)
        fixOptionalContent()
        fixEmbeddedFiles(parts)
        try fixFonts(before)
        try setOutputIntent()
        try setMetadata()
        document.catalog.remove("Version")
    }

    func changed(_ text: String) { changes.append(text) }

    // The header is written by the saver from the document's version; the same number of bytes, so the offsets hold.
    private func setHeaderVersion(_ bytes: inout [UInt8]) {
        let version = Array((part == 1 ? "1.4" : part == 4 ? "2.0" : "1.7").utf8)
        if bytes.count < 8 { return }
        for i in 0..<3 { bytes[5 + i] = version[i] }
    }
}
