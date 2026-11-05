import Foundation

// Twin of windows/LazyPDF.Core/Optimize/PdfSanitizer.cs: "Clean for sharing". `scan` lists what the file holds; `run`
// writes a new file without the chosen kinds. The file is always rewritten, so earlier versions and unreferenced
// objects go with it, and the document is not changed. Signatures do not survive, and neither do their values,
// appearances, /DSS and /Perms. The output keeps the encryption of the input unless `SanitizeOptions.keepEncryption`
// is off or a handler is given.

public final class PdfSanitizer {
    private static let everything = SanitizeOptions(invisibleText: true)

    private let document: PdfDocument

    public init(_ document: PdfDocument) {
        self.document = document
    }

    /// What was found, each with a count, in the order of `SanitizeItem`.
    public func scan() throws -> [SanitizeFinding] {
        let working = try PdfDocument.open(document.saveRewrite())
        let (found, _, _) = try apply(working, Self.everything)
        return Self.findings(found)
    }

    public func run(_ options: SanitizeOptions) throws -> SanitizeResult {
        let working = try PdfDocument.open(document.saveRewrite())
        let (found, stripped, taken) = try apply(working, options)
        var removed: [SanitizeItem: Int] = [:]
        var kept: [SanitizeItem: Int] = [:]
        for (item, count) in found {
            let gone: Int
            if let exact = taken[item] {
                gone = exact
            } else if !Self.isRemoved(item, options) {
                gone = 0
            } else {
                gone = item == .invisibleText ? stripped : count
            }
            removed[item] = gone
            kept[item] = count - gone
        }
        let security = options.security ?? (options.keepEncryption ? document.security : nil)
        // The keys of the older handlers are made from the first /ID, so a handler taken over from the input keeps the id it was made with.
        let inherited = security != nil && security === document.security
        let id: [UInt8]?
        if inherited, let revision = security?.revision, revision < 5 {
            id = document.firstId
        } else {
            id = options.documentId ?? (inherited ? document.firstId : nil)
        }
        let bytes = try working.saveRewrite(PdfSaveOptions(useObjectStreams: false, security: security, documentId: id))
        return SanitizeResult(bytes: bytes, removed: Self.findings(removed), kept: Self.findings(kept), sizeBefore: document.length, sizeAfter: bytes.count)
    }

    private static func findings(_ counts: [SanitizeItem: Int]) -> [SanitizeFinding] {
        counts.filter { $0.value > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }.map { SanitizeFinding($0.key, $0.value) }
    }

    private static func isRemoved(_ item: SanitizeItem, _ o: SanitizeOptions) -> Bool {
        switch item {
        case .javaScript: return o.javaScript
        case .launchActions: return o.launchActions
        case .embeddedFiles: return o.embeddedFiles
        case .hiddenLayers: return o.hiddenLayers
        case .invisibleText: return o.invisibleText
        case .comments: return o.comments
        case .formData: return o.formData
        case .metadata: return o.metadata
        case .pieceInfo: return o.pieceInfo
        case .thumbnails: return o.thumbnails
        case .searchIndexes: return o.searchIndexes
        case .externalLinks: return o.externalLinks
        case .filePaths: return o.filePaths
        case .previousVersions, .signatures: return true
        case .hiddenText: return false
        }
    }

    // Counts everything and removes what the options choose; returns the counts, the number of invisible shows taken out
    // and, for the kinds of action, how many were taken (a rendition with a script goes under either option).
    private func apply(_ working: PdfDocument, _ o: SanitizeOptions) throws -> (found: [SanitizeItem: Int], stripped: Int, taken: [SanitizeItem: Int]) {
        var found: [SanitizeItem: Int] = [.signatures: SanitizeSignatures.strip(working)]
        let text = SanitizeText(working)
        let (hidden, invisible) = text.count()
        found[.hiddenText] = hidden
        found[.invisibleText] = invisible
        var stripped = 0
        if o.invisibleText && invisible > 0 { stripped = try text.strip() }

        found[.hiddenLayers] = try SanitizeLayers(working).run(o.hiddenLayers)
        let (actions, taken) = try SanitizeActions.run(working, o.javaScript, o.launchActions, o.externalLinks)
        found[.javaScript] = actions.javaScript
        found[.launchActions] = actions.launch
        found[.externalLinks] = actions.uri
        found[.embeddedFiles] = SanitizeData.embeddedFiles(working, o.embeddedFiles)
        found[.comments] = SanitizeData.comments(working, o.comments)
        found[.formData] = try SanitizeData.formData(working, o.formData)
        found[.metadata] = SanitizeData.metadata(working, o.metadata)
        found[.pieceInfo] = SanitizeData.pieceInfo(working, o.pieceInfo)
        found[.thumbnails] = SanitizeData.thumbnails(working, o.thumbnails)
        found[.searchIndexes] = SanitizeData.searchIndexes(working, o.searchIndexes)
        found[.filePaths] = SanitizeData.filePaths(working, o.filePaths)
        found[.previousVersions] = max(0, document.sectionOffsets.count - (document.wasLinearized ? 2 : 1))
        let gone: [SanitizeItem: Int] = [.javaScript: taken.javaScript, .launchActions: taken.launch, .externalLinks: taken.uri]
        return (found, stripped, gone)
    }
}
