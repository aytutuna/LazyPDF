import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchRunner.cs. Runs a set's steps over one file at a time and writes the result under
// a new name in the output folder. The source is only read, and a result never replaces a file that is already there. A Bates
// step moves its own `start` on to the number after the last page, so the set it is given carries the count.

/// `output` is where the result was written; nil when the file failed.
public struct BatchResult: Equatable {
    public let input: URL
    public let output: URL?
    public let ok: Bool
    public let title: String
    public let detail: String

    public init(input: URL, output: URL?, ok: Bool, title: String, detail: String) {
        self.input = input
        self.output = output
        self.ok = ok
        self.title = title
        self.detail = detail
    }
}

private struct StepFailed: Error {
    let problem: Problem
}

public final class BatchRunner: @unchecked Sendable {
    private let codec: ImageCodec
    private let fonts: FontSource?
    private let recognizer: TextRecognizer
    private let renderers: () -> DocumentRenderer
    private let writer: FileWriter
    private let reader: (URL) throws -> Data

    /// On iOS the files are where a provider keeps them, so the shells hand in a coordinated reader and writer.
    public init(codec: ImageCodec, fonts: FontSource?, recognizer: TextRecognizer, renderers: @escaping () -> DocumentRenderer,
                writer: FileWriter = PlainFileWriter(), reader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.codec = codec
        self.fonts = fonts
        self.recognizer = recognizer
        self.renderers = renderers
        self.writer = writer
        self.reader = reader
    }

    /// Throws CancellationError when `token` is cancelled; a file that cannot be done is a result, not an error.
    public func run(_ file: URL, _ set: inout BatchSet, into folder: URL, number: Int, now: DateTimeOffset, token: CancelToken) async throws -> BatchResult {
        let name = file.lastPathComponent
        var bytes: [UInt8]
        var notes: [String] = []
        do {
            bytes = [UInt8](try reader(file))
            try token.throwIfCancelled()
            let source = try PdfDocument.open(bytes)
            if source.isSigned {
                return BatchResult(input: file, output: nil, ok: false, title: L10n.t("File is signed"),
                                   detail: L10n.t("{0} has a signature that these steps would break. Open it and sign it again afterwards.", name))
            }
            if ToolDocuments.needsOwner(source) {
                return BatchResult(input: file, output: nil, ok: false, title: L10n.t("File is protected"),
                                   detail: L10n.t("{0} limits what may be done to it. Ask its owner for a copy without limits.", name))
            }
            for i in set.steps.indices {
                try token.throwIfCancelled()
                bytes = try await apply(&set.steps[i], last: i == set.steps.count - 1, bytes, now, &notes, token)
            }
            try token.throwIfCancelled()
            try checkPdfA(set, bytes, &notes)
        } catch let failed as StepFailed {
            return BatchResult(input: file, output: nil, ok: false, title: failed.problem.title, detail: failed.problem.text)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PdfReadException where error.problem == .passwordRequired || error.problem == .certificateRequired {
            return BatchResult(input: file, output: nil, ok: false, title: L10n.t("File is locked"),
                               detail: L10n.t("{0} needs a password or certificate, and Batch cannot ask for one. Take the lock off first, then add the file again.", name))
        } catch {
            let problem = Problems.open(error, name)
            return BatchResult(input: file, output: nil, ok: false, title: problem.title, detail: problem.text)
        }

        let stem = (name as NSString).deletingPathExtension
        let target = unique(folder.appendingPathComponent(BatchNames.apply(set.nameTemplate, stem, number, now)))
        try token.throwIfCancelled()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writer.write(to: target) { try PdfFileSaver.save($0.path, bytes) }
        } catch {
            let problem = Problems.save(error, target.lastPathComponent)
            return BatchResult(input: file, output: nil, ok: false, title: problem.title, detail: problem.text)
        }
        return BatchResult(input: file, output: target, ok: true, title: notes.isEmpty ? L10n.t("Done") : L10n.t("Done, with notes"),
                           detail: ([target.lastPathComponent] + notes).joined(separator: " "))
    }

    private func apply(_ step: inout BatchStep, last: Bool, _ bytes: [UInt8], _ now: DateTimeOffset, _ notes: inout [String],
                       _ token: CancelToken) async throws -> [UInt8] {
        switch step.kind {
        case .ocr:
            return try await ocr(step, bytes, &notes)
        case .compress:
            let document = try PdfDocument.open(bytes)
            // Keeps the file's own encryption, as Make smaller does.
            var options = OptimizeOptions.for(step.preset.preset)
            options.security = document.security
            options.documentId = document.security == nil ? nil : document.firstId
            let result = try PdfOptimizer(document, codec).run(options)
            try token.throwIfCancelled()
            if result.bytes.count >= bytes.count {
                notes.append(L10n.t("Could not be made smaller, so it was left as it was."))
                return bytes
            }
            notes += result.notes
            return result.bytes
        case .clean:
            let document = try PdfDocument.open(bytes)
            let result = try PdfSanitizer(document).run(SanitizeOptions(embeddedFiles: !step.keepAttachments, comments: !step.keepComments,
                                                                         formData: !step.keepForms, externalLinks: !step.keepLinks))
            try token.throwIfCancelled()
            if !result.kept.isEmpty {
                notes.append(L10n.plural(result.kept.count, one: "{0} kind of private data is left in.", other: "{0} kinds of private data are left in."))
            }
            return result.bytes
        case .watermark:
            return try watermark(step, bytes, &notes)
        case .bates:
            return try bates(&step, bytes, &notes)
        case .pdfA:
            let converted = try PdfAConverter(fonts).convert(bytes, step.level.level, now)
            try token.throwIfCancelled()
            guard let made = converted.bytes else {
                throw StepFailed(problem: Problem(L10n.t("Not converted to PDF/A"), converted.refusal ?? ""))
            }
            notes += converted.changes
            if last && !converted.remaining.isEmpty { notes.append(Self.rulesLeft(converted.remaining.count)) }
            return made
        }
    }

    private static func rulesLeft(_ count: Int) -> String {
        L10n.plural(count, one: "{0} PDF/A rule is left.", other: "{0} PDF/A rules are left.")
    }

    // Steps after PDF/A can undo it, so what is left is counted on the finished file.
    private func checkPdfA(_ set: BatchSet, _ bytes: [UInt8], _ notes: inout [String]) throws {
        guard let at = set.steps.lastIndex(where: { $0.kind == .pdfA }), at != set.steps.count - 1 else { return }
        let made = try PdfDocument.open(bytes)
        let left = PdfAValidator.validate(made, set.steps[at].level.level).issues.count
        if left > 0 { notes.append(Self.rulesLeft(left)) }
    }

    private func ocr(_ step: BatchStep, _ bytes: [UInt8], _ notes: inout [String]) async throws -> [UInt8] {
        let session = try PdfEditSession.open(bytes)
        let renderer = renderers()
        defer { renderer.close() }
        if !renderer.load(session, nil) {
            throw StepFailed(problem: Problem(L10n.t("Pages cannot be drawn"), L10n.t("The system cannot draw this file, so its text cannot be read.")))
        }
        let options = OcrOptions(language: step.text.isEmpty ? "en-US" : step.text)
        let result: OcrResult
        do {
            result = try await PdfSearchable.runAsync(session, recognizer, renderer, options)
        } catch let error as InvalidOperationException {
            throw StepFailed(problem: Problem(L10n.t("Text cannot be read"), error.message))
        }
        if result.notRendered > 0 {
            notes.append(L10n.plural(result.notRendered, one: "{0} page could not be drawn.", other: "{0} pages could not be drawn."))
        }
        if result.noWords > 0 {
            notes.append(L10n.plural(result.noWords, one: "No text found on {0} page. Check the language.", other: "No text found on {0} pages. Check the language."))
            notes.append(L10n.t("Pages that are turned sideways cannot be read."))
        }
        return session.current
    }

    private func watermark(_ step: BatchStep, _ bytes: [UInt8], _ notes: inout [String]) throws -> [UInt8] {
        if step.text.trimmingCharacters(in: .whitespaces).isEmpty {
            throw StepFailed(problem: Problem(L10n.t("Watermark has no text"), L10n.t("Type the watermark text in the step, then run again.")))
        }
        let session = try PdfEditSession.open(bytes)
        var spec = WatermarkSpec(text: step.text)
        spec.opacity = Double(min(max(step.opacity, 5), 100)) / 100
        spec.rotation = Double(step.angle)
        spec.scale = Double(min(max(step.size, 10), 100)) / 100
        spec.anchor = step.anchor
        _ = try stamp(session, &notes, "Watermark") { try $0.addWatermark(spec) }
        return session.current
    }

    private func bates(_ step: inout BatchStep, _ bytes: [UInt8], _ notes: inout [String]) throws -> [UInt8] {
        let session = try PdfEditSession.open(bytes)
        let band: HeaderFooterBand
        switch step.place {
        case .footerCenter, .headerCenter: band = HeaderFooterBand("", "{bates}", "")
        case .footerLeft, .headerLeft: band = HeaderFooterBand("{bates}", "", "")
        default: band = HeaderFooterBand("", "", "{bates}")
        }
        let header = step.place.rawValue >= BatesPlace.headerRight.rawValue
        let spec = HeaderFooterSpec(header: header ? band : HeaderFooterBand(), footer: header ? HeaderFooterBand() : band,
                                    bates: BatesSpec(prefix: step.text, suffix: step.suffix, digits: step.digits, start: step.start))
        let run = try stamp(session, &notes, "Bates numbers") { try $0.addHeaderFooter(spec) }
        step.start = run.nextBates
        return session.current
    }

    private func stamp(_ session: PdfEditSession, _ notes: inout [String], _ label: String, _ add: (PdfStamper) throws -> StampRun) throws -> StampRun {
        do {
            let run = try add(PdfStamper(session.document, fonts))
            try session.commit(label)
            if !run.missing.isEmpty { notes.append(L10n.t("Some characters are missing")) }
            return run
        } catch is InvalidOperationException {
            throw StepFailed(problem: Problem(L10n.t("No font for the text"), L10n.t("Use other text, or install a font that has these letters.")))
        }
    }

    // A name that is not taken: "a.pdf", then "a (2).pdf".
    private func unique(_ url: URL) -> URL {
        var path = url
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while FileManager.default.fileExists(atPath: path.path) {
            path = folder.appendingPathComponent("\(stem) (\(i)).pdf")
            i += 1
        }
        return path
    }
}
