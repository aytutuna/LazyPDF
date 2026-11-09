import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Export/Exporter.cs. The Mac is sandboxed and iOS reads only what the person picked, so
// Write puts its files in a folder of the app's own and the window hands them to the file exporter; it takes no path from
// the person.

/// The document as the export reads it: the bytes at the time, and what is needed to open them again.
public struct ExportSource {
    public var pdf: [UInt8]
    public var password: String?
    public var certificate: X509Certificate?
    public var renderer: PageRenderer
    public var codec: ImageCodec?
    public var stem: String

    public init(pdf: [UInt8], password: String?, certificate: X509Certificate?, renderer: PageRenderer, codec: ImageCodec?, stem: String) {
        self.pdf = pdf
        self.password = password
        self.certificate = certificate
        self.renderer = renderer
        self.codec = codec
        self.stem = stem
    }
}

public enum Exporter {
    // The sheets XlsxWriter stops at.
    private static let mostSheets = 1000

    /// False when the file was opened with a password that does not allow copying content out.
    public static func allowed(_ document: PdfDocument) -> Bool {
        guard let security = document.security, !security.openedAsOwner else { return true }
        return security.permissions.contains(.copy)
    }

    /// `certificate` is the identity the tab's file was opened with, from `ToolHost.verifyCertificate`.
    @MainActor
    public static func source(_ tab: DocumentTab, _ host: ToolHost, codec: ImageCodec?) -> ExportSource {
        ExportSource(pdf: tab.session.current, password: tab.password, certificate: tab.certificate.flatMap { host.verifyCertificate($0) },
                     renderer: tab.renderer, codec: codec, stem: (tab.title as NSString).deletingPathExtension)
    }

    /// A renderer on its own copy of the bytes. The tab's renderer follows Undo and Redo, which stay open to the toolbar
    /// during an export, so pictures of pages would come from two states of the file. Nil when the system cannot read the copy.
    public static func snapshot(_ source: ExportSource, _ make: () -> DocumentRenderer) -> DocumentRenderer? {
        guard let session = try? openSession(source) else { return nil }
        let renderer = make()
        if renderer.load(session, source.password) { return renderer }
        renderer.close()
        return nil
    }

    private static func openSession(_ source: ExportSource) throws -> PdfEditSession {
        #if canImport(Security)
        if let certificate = source.certificate, let held = PdfCertificate(certificate) { return try PdfEditSession.open(source.pdf, certificate: held) }
        #endif
        return try PdfEditSession.open(source.pdf, password: source.password)
    }

    /// Writes into `folder`: one file named after the document, or the pictures. Runs off the main actor.
    public static func write(_ source: ExportSource, _ options: ExportOptions, to folder: URL, _ token: CancelToken) throws -> ExportResult {
        let document = try ToolDocuments.open(source.pdf, password: source.password, certificate: source.certificate)
        if options.format == .pictures { return try pictures(document, source, options, folder, token) }
        if options.format == .images { return try images(document, source, options, folder, token) }

        let model = try ExportLayout.analyze(document, options.pages, source.codec)
        try token.throwIfCancelled()
        if !model.pages.contains(where: { !$0.lines.isEmpty }) { return ExportResult(files: [], gap: .noText) }
        let target = folder.appendingPathComponent(source.stem + options.fileExtension)
        switch options.format {
        case .word: try save(target, try DocxWriter.make(model))
        case .excel: try save(target, try XlsxWriter.make(model))
        case .powerPoint: try save(target, try PptxWriter.make(model))
        case .html: try saveText(target, options.fixedHtml ? try HtmlWriter.fixed(model) : try HtmlWriter.reflowed(model))
        case .markdown: try saveText(target, try MarkdownWriter.make(model, embedImages: options.markdownPictures))
        case .rtf: try saveText(target, try RtfWriter.make(model))
        default: try saveText(target, try PlainTextWriter.make(model))
        }
        return ExportResult(files: [target], gap: options.format == .excel ? excelGap(model) : .none, picturesLeftOut: model.picturesLeftOut)
    }

    // With tables a workbook has a sheet for each table and none for the text around them, otherwise a sheet for each page.
    static func excelGap(_ model: ExportDocument) -> ExportGap {
        if model.tables.isEmpty { return model.pages.count > mostSheets ? .pastSheetLimit : .none }
        if model.pages.contains(where: { $0.blocks.contains { $0 is ExportParagraph } }) { return .outsideTables }
        return model.tables.count > mostSheets ? .pastSheetLimit : .none
    }

    private static func pictures(_ document: PdfDocument, _ source: ExportSource, _ options: ExportOptions, _ folder: URL,
                                 _ token: CancelToken) throws -> ExportResult {
        let pages = options.pages ?? Array(0..<document.pages.count)
        let digits = String(document.pages.count).count
        let fileExtension = options.picture == .png ? ".png" : ".jpg"
        var written: [URL] = []
        var skipped = 0
        for page in pages {
            try token.throwIfCancelled()
            let bytes: [UInt8]?
            if options.picture == .png {
                bytes = try PageImages.png(source.renderer, page, Double(options.dpi))
            } else if let codec = source.codec {
                bytes = try PageImages.jpeg(source.renderer, codec, page, Double(options.dpi), options.quality)
            } else {
                bytes = nil
            }
            guard let bytes else {
                skipped += 1
                continue
            }
            let number = String(page + 1)
            let name = "\(source.stem) page \(String(repeating: "0", count: max(digits - number.count, 0)) + number)\(fileExtension)"
            let target = unique(folder, name)
            try save(target, bytes)
            written.append(target)
        }
        return ExportResult(files: written, skipped: skipped)
    }

    // One page at a time: the extractor holds every picture of a call in memory under one budget, which a long scan would use up.
    private static func images(_ document: PdfDocument, _ source: ExportSource, _ options: ExportOptions, _ folder: URL,
                               _ token: CancelToken) throws -> ExportResult {
        var written: [URL] = []
        for page in options.pages ?? Array(0..<document.pages.count) {
            for image in try ImageExtractor.extract(document, [page], source.codec) {
                try token.throwIfCancelled()
                let target = unique(folder, image.fileName)
                try save(target, image.image.data)
                written.append(target)
            }
        }
        return ExportResult(files: written)
    }

    // A file written beside others never goes over one that is there.
    private static func unique(_ folder: URL, _ name: String) -> URL {
        var path = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, fileExtension = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: path.path) {
            path = folder.appendingPathComponent("\(stem) (\(n))" + (fileExtension.isEmpty ? "" : "." + fileExtension))
            n += 1
        }
        return path
    }

    private static func saveText(_ url: URL, _ text: String) throws {
        try save(url, Array(text.utf8))
    }

    // Written under a temporary name and moved, so a failed write leaves no half file.
    private static func save(_ url: URL, _ bytes: [UInt8]) throws {
        let temp = URL(fileURLWithPath: url.path + "." + UUID().uuidString + ".tmp")
        do {
            try Data(bytes).write(to: temp)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
