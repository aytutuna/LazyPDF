import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/CompareFlow.cs: the long parts of the tool, running a comparison and writing its
// report, with the busy bar and the messages.

/// `url` is the other file, which the caller has access to; nil when `version` is given. `fileIsOlder`: with `url`, the open
/// file is the old side. `password` opens the other file (the open file's own is tried when nil) and `certificate` does when
/// it is encrypted for recipients.
public struct CompareRequest {
    public var url: URL?
    public var version: PdfVersion?
    public var fileIsOlder: Bool
    public var options: CompareOptions
    public var byPixels: Bool
    public var password: String?
    public var certificate: CertificateChoice?

    public init(url: URL?, version: PdfVersion? = nil, fileIsOlder: Bool = false, options: CompareOptions = CompareOptions(),
                byPixels: Bool = false, password: String? = nil, certificate: CertificateChoice? = nil) {
        self.url = url
        self.version = version
        self.fileIsOlder = fileIsOlder
        self.options = options
        self.byPixels = byPixels
        self.password = password
        self.certificate = certificate
    }
}

@MainActor
public final class CompareFlow {
    private let host: ToolHost
    private let renderers: () -> DocumentRenderer
    private let fonts: FontSource

    /// What the other file of the last run needs to be opened; nil when it opened or was not the reason the run failed.
    public private(set) var locked: PdfReadProblem?

    public init(_ host: ToolHost, _ renderers: @escaping () -> DocumentRenderer, _ fonts: FontSource) {
        self.host = host
        self.renderers = renderers
        self.fonts = fonts
    }

    /// The finished comparison, or nil when it was cancelled or a file could not be read.
    public func run(_ tab: DocumentTab, _ request: CompareRequest) async throws -> CompareSession? {
        locked = nil
        let host = host
        let open = CompareSide.of(tab, host)
        let earlier = request.version.map { CompareSide.of(tab, $0, host) }
        let password = request.password ?? tab.password
        let certificate = request.certificate.flatMap { host.verifyCertificate($0) }
        var made: CompareSession?
        do {
            try await host.runBusy(L10n.t("Comparing files")) { [self] token in
                let oldRenderer = renderers(), newRenderer = renderers()
                // Loading a renderer can decrypt a whole file, so it is part of the step off the main actor.
                let (before, after, oldSession, newSession, drawn) = try await ToolDocuments.run(token) { () throws -> (CompareSide, CompareSide, PdfEditSession, PdfEditSession, (old: Bool, new: Bool)) in
                    let other = try earlier ?? CompareSide.of(request.url!, password: password, choice: request.certificate, certificate: certificate)
                    let (before, after) = earlier != nil ? (other, open) : request.fileIsOlder ? (open, other) : (other, open)
                    let first = try before.openSession(), second = try after.openSession()
                    try Task.checkCancellation()
                    return (before, after, first, second, (oldRenderer.load(first, before.password), newRenderer.load(second, after.password)))
                }
                try token.throwIfCancelled()
                let session = CompareSession(before, after, oldSession: oldSession, newSession: newSession, oldRenderer: oldRenderer,
                                             newRenderer: newRenderer, drawn: drawn)
                do {
                    try await session.compare(request.options, byPixels: request.byPixels, token)
                } catch {
                    session.dispose()
                    throw error
                }
                made = session
            }
        } catch let error as PdfReadException {
            if (error.problem == .passwordRequired || error.problem == .certificateRequired) && request.url != nil {
                locked = error.problem
                return nil
            }
            host.showProblem(Problems.open(error, request.url?.lastPathComponent ?? tab.title))
            return nil
        } catch where Problems.isFileSystem(error) {
            host.showProblem(Problems.open(error, request.url?.lastPathComponent ?? tab.title))
            return nil
        }
        if let made { host.setStatus(Self.headline(made, made.rows(.all).count)) }
        return made
    }

    public func writeReport(_ session: CompareSession, _ parts: CompareParts) async {
        if !session.canReport {
            host.showProblem(Problem(L10n.t("Report not allowed"),
                                     L10n.t("{0} limits what readers may do. Open it with its owner password to write a report.", session.new.title)))
            return
        }
        let filtered = !session.byPixels && parts != .all
        if filtered, ChangeParts.only(session.result!, parts).isIdentical, !session.result!.isIdentical {
            host.showProblem(Problem(L10n.t("Nothing to report"), L10n.t("No difference matches the kinds switched on. Switch on more kinds under Show.")))
            return
        }
        var report: [UInt8]?
        do {
            let work = session.reportWork(parts, fonts)
            try await host.runBusy(L10n.t("Writing report")) { token in
                let written = try await ToolDocuments.run(token, work)
                try token.throwIfCancelled()
                report = written
            }
        } catch {
            host.showProblem(Problem(L10n.t("Report not written"), L10n.t("The report could not be built from this comparison. Run the comparison again.")))
            return
        }
        guard let report else { return }
        let stem = (session.new.title as NSString).deletingPathExtension
        let title = filtered ? L10n.t("{0}, filtered - {1}.pdf", CompareText.title, stem) : "\(CompareText.title) - \(stem).pdf"
        await host.openNew(report, title: title, password: session.new.password, certificate: session.new.certificate)
    }

    /// The states of the file that differ from the one open: a version that ends where the file ends is the file itself.
    public static func earlier(_ session: PdfEditSession) -> [PdfVersion] {
        session.versions.filter { $0.end < session.current.count }
    }

    /// What the panel says over the list: how many differences are shown.
    public static func headline(_ session: CompareSession, _ shown: Int) -> String {
        if shown > 0 {
            return session.byPixels ? L10n.plural(shown, one: "{0} area differs", other: "{0} areas differ") : CompareText.changeCount(shown)
        }
        if session.byPixels { return session.looked == 0 && session.undrawn > 0 ? L10n.t("Pages could not be drawn.") : CompareText.noDifferences }
        return session.result!.isIdentical ? CompareText.noDifferences : L10n.t("Nothing to show with these filters.")
    }

    /// A line under the headline: the words added and removed, or what a pixel comparison left out; nil when there is nothing
    /// to add.
    public static func note(_ session: CompareSession) -> String? {
        if session.byPixels {
            if session.pixelCapped { return L10n.t("Only the first {0} places are listed.", CompareSession.maxPixelRows) }
            return session.undrawn > 0 ? L10n.plural(session.undrawn, one: "{0} page could not be drawn.", other: "{0} pages could not be drawn.") : nil
        }
        let summary = session.result!.summary
        return summary.wordsAdded + summary.wordsRemoved == 0 ? nil : L10n.t("Words: {0} added, {1} removed", summary.wordsAdded, summary.wordsRemoved)
    }
}
