import Foundation

// Twin of windows/LazyPDF.Core/Optimize/PdfOptimizer.cs: makes a file smaller by a full rewrite (`saveRewrite`)
// with the steps the options choose. The document is not changed: the steps run on a copy made from a plain
// rewrite, and the result is never larger than that rewrite, unless the file is made gray, encrypted or given an
// id. Signatures do not survive.
//
// The deflated bytes are the engine's own Deflate, so a size compared to another (the packed save against the
// plain one) can fall the other way than in the C#.

public final class PdfOptimizer {
    private let document: PdfDocument
    private let codec: ImageCodec?

    public init(_ document: PdfDocument, _ codec: ImageCodec? = nil) {
        self.document = document
        self.codec = codec
    }

    /// The space audit of the file and the steps `options` would run.
    public func plan(_ options: OptimizeOptions) -> OptimizePlan {
        var steps: [OptimizeStepKind] = [.removeUnreferenced]
        func add(_ on: Bool, _ kind: OptimizeStepKind) {
            if on { steps.append(kind) }
        }
        add(options.stripThumbnails, .stripThumbnails)
        add(options.stripPieceInfo, .stripPieceInfo)
        add(options.stripPrivateData, .stripPrivateData)
        add(options.pruneResources, .pruneResources)
        add(options.removeDuplicates, .removeDuplicates)
        add(options.subsetFonts, .subsetFonts)
        add(options.grayscale, .grayscale)
        add(options.bilevelTolerance >= 0, .bilevelImages)
        add(options.imageDpi > 0, .downsampleImages)
        add(options.recompressStreams, .recompressStreams)
        add(options.convertOldFilters, .convertOldFilters)
        add(options.objectStreams, .objectStreams)
        return OptimizePlan(audit: audit(), steps: steps)
    }

    public func audit() -> SpaceAudit { PdfSpaceAudit(document).run() }

    public func run(_ options: OptimizeOptions) throws -> OptimizeResult {
        let before = self.audit()
        let plain = try document.saveRewrite()
        let working = try PdfDocument.open(plain)
        var results = [OptimizeStepResult(.removeUnreferenced, unreferencedCount())]
        var notes: [String] = []
        func did(_ kind: OptimizeStepKind, _ count: Int) { results.append(OptimizeStepResult(kind, count)) }

        if options.stripThumbnails { did(.stripThumbnails, OptimizeStrip.thumbnails(working)) }
        if options.stripPieceInfo { did(.stripPieceInfo, OptimizeStrip.pieceInfo(working)) }
        if options.stripPrivateData { did(.stripPrivateData, OptimizeStrip.privateData(working)) }
        if options.pruneResources { did(.pruneResources, OptimizeResources(working).run()) }
        let merged = options.removeDuplicates ? OptimizeDuplicates.run(working) : 0
        if options.subsetFonts {
            let (trimmed, partial) = OptimizeFonts(working).run()
            did(.subsetFonts, trimmed)
            if partial { notes.append(OptimizeText.leftPartialFonts) }
        }
        if options.grayscale {
            let gray = OptimizeGray(working, codec, options.jpegQuality)
            gray.run()
            did(.grayscale, gray.streams + gray.images)
            if gray.left > 0 { notes.append(OptimizeText.leftColor) }
            if gray.needsCodec { notes.append(OptimizeText.needsCodec) }
        }
        if options.bilevelTolerance >= 0 || options.imageDpi > 0 {
            let images = OptimizeImages(working, options, codec)
            images.run()
            if options.bilevelTolerance >= 0 { did(.bilevelImages, images.bilevel) }
            if options.imageDpi > 0 { did(.downsampleImages, images.downsampled) }
            if images.partial { notes.append(OptimizeText.leftPartialImages) }
            if images.needsCodec && !notes.contains(OptimizeText.needsCodec) { notes.append(OptimizeText.needsCodec) }
        }
        let (recompressed, converted) = OptimizeStreams.run(working, options.recompressStreams, options.convertOldFilters)
        if options.recompressStreams { did(.recompressStreams, recompressed) }
        if options.convertOldFilters { did(.convertOldFilters, converted) }
        if options.removeDuplicates { did(.removeDuplicates, merged + OptimizeDuplicates.run(working)) }

        var best = try save(working, options, false)
        if options.objectStreams && document.pdfAPart != 1 {
            let packed = try save(working, options, true)
            let usePacked = packed.count < best.count
            if usePacked { best = packed }
            did(.objectStreams, usePacked ? 1 : 0)
        }
        // A plain rewrite is the floor, unless the file was asked to change its look or to be encrypted or given an id.
        if best.count > plain.count && !options.grayscale && options.security == nil && options.documentId == nil { best = plain }
        return OptimizeResult(bytes: best, sizeBefore: document.length, sizeAfter: best.count, audit: before, steps: results, notes: notes)
    }

    private func save(_ working: PdfDocument, _ options: OptimizeOptions, _ objectStreams: Bool) throws -> [UInt8] {
        try working.saveRewrite(PdfSaveOptions(useObjectStreams: objectStreams, security: options.security, documentId: options.documentId))
    }

    private func unreferencedCount() -> Int {
        var reached = Set<Int>()
        var queue: [PdfObject?] = [document.trailer]
        var next = 0
        while next < queue.count {
            let root = queue[next]
            next += 1
            for reference in PdfGraph.references(root) where reached.insert(reference.number).inserted {
                queue.append(document.get(reference.number))
            }
        }
        return document.objectNumbers.filter { !reached.contains($0) && document.get($0) != nil }.count
    }
}
