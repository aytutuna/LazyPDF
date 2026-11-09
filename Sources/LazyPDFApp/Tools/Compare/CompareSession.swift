import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/CompareSession.cs. Two files opened as documents of their own, the result of
// comparing them, and the rows that show it. The tabs are for the side by side sheet and the renderers; nothing here
// touches the document the person has open. The comparison itself runs off the main actor on the documents of the tabs.

/// One file of a comparison as bytes, so the open document can go on changing while the comparison runs.
public struct CompareSide {
    public let bytes: [UInt8]
    public let name: String
    public let password: String?

    /// The identity the file was opened with, as the tab remembers it, and the certificate that opens the bytes again.
    public let choice: CertificateChoice?
    public let certificate: X509Certificate?

    public init(bytes: [UInt8], name: String, password: String?, choice: CertificateChoice? = nil, certificate: X509Certificate? = nil) {
        self.bytes = bytes
        self.name = name
        self.password = password
        self.choice = choice
        self.certificate = certificate
    }

    @MainActor
    public static func of(_ tab: DocumentTab, _ host: ToolHost) -> CompareSide {
        CompareSide(bytes: tab.session.current, name: tab.title, password: tab.password, choice: tab.certificate,
                    certificate: tab.certificate.flatMap { host.verifyCertificate($0) })
    }

    @MainActor
    public static func of(_ tab: DocumentTab, _ version: PdfVersion, _ host: ToolHost) -> CompareSide {
        CompareSide(bytes: tab.session.extractVersion(version), name: L10n.t("{0}, version {1}", tab.title, version.number),
                    password: tab.password, choice: tab.certificate, certificate: tab.certificate.flatMap { host.verifyCertificate($0) })
    }

    /// Reads the other file, which the caller has access to.
    public static func of(_ url: URL, password: String?, choice: CertificateChoice?, certificate: X509Certificate?) throws -> CompareSide {
        CompareSide(bytes: [UInt8](try Data(contentsOf: url)), name: url.lastPathComponent, password: password, choice: choice, certificate: certificate)
    }

    public func openSession() throws -> PdfEditSession {
        #if canImport(Security)
        if let certificate, let held = PdfCertificate(certificate) { return try PdfEditSession.open(bytes, certificate: held) }
        #endif
        return try PdfEditSession.open(bytes, password: password)
    }

    func reopen() throws -> PdfDocument {
        try ToolDocuments.open(bytes, password: password, certificate: certificate)
    }
}

// Outside the class, which belongs to the main actor, so the comparison on another thread may read them.
private let pixelRowLimit = 1000
private let pixelDpi = 96.0
private let rowsPerPage = 50
private let reportMarks = 5001

@MainActor
public final class CompareSession {
    public static let maxPixelRows = pixelRowLimit

    private struct Outcome {
        var result: LazyPDFKit.ComparisonResult
        var rows: [(part: CompareParts, row: ChangeRow)]
        var pixelRows: [ChangeRow] = []
        var pixelResult: LazyPDFKit.ComparisonResult?
        var looked = 0
        var undrawn = 0
        var capped = false
    }

    private let before: CompareSide
    private let after: CompareSide
    private var contentRows: [(part: CompareParts, row: ChangeRow)] = []
    private var pixelRows: [ChangeRow] = []
    private var pixelResult: LazyPDFKit.ComparisonResult?

    public let old: DocumentTab
    public let new: DocumentTab

    /// What the content comparison found; the pages of a pixel comparison are paired from it as well.
    public private(set) var result: LazyPDFKit.ComparisonResult?

    public private(set) var byPixels = false

    /// Pairs of pages a pixel comparison looked at, and those it could not because one of them cannot be drawn.
    public private(set) var looked = 0
    public private(set) var undrawn = 0

    /// A pixel comparison found more areas than it lists.
    public private(set) var pixelCapped = false

    /// With sessions opened already, off the main actor.
    public init(_ before: CompareSide, _ after: CompareSide, oldSession: PdfEditSession, newSession: PdfEditSession,
                _ renderers: () -> DocumentRenderer) {
        self.before = before
        self.after = after
        old = DocumentTab(session: oldSession, renderer: renderers(), url: nil, title: before.name, password: before.password,
                          certificate: before.choice)
        new = DocumentTab(session: newSession, renderer: renderers(), url: nil, title: after.name, password: after.password,
                          certificate: after.choice)
    }

    public convenience init(_ before: CompareSide, _ after: CompareSide, _ renderers: () -> DocumentRenderer) throws {
        self.init(before, after, oldSession: try before.openSession(), newSession: try after.openSession(), renderers)
    }

    /// The report is a copy of the new file; a file that limits what readers may do can only be copied by its owner.
    public var canReport: Bool {
        guard let security = new.document.security else { return true }
        return security.openedAsOwner || security.permissions == .all
    }

    public func compare(_ options: CompareOptions, byPixels: Bool, _ token: CancelToken = CancelToken()) async throws {
        let before = old.document, after = new.document, oldRenderer = old.renderer, newRenderer = new.renderer
        let outcome = try await ToolDocuments.run(token) {
            try Self.work(before, after, oldRenderer, newRenderer, options, byPixels, token)
        }
        try token.throwIfCancelled()
        contentRows = outcome.rows
        pixelRows = outcome.pixelRows
        pixelResult = outcome.pixelResult
        looked = outcome.looked
        undrawn = outcome.undrawn
        pixelCapped = outcome.capped
        self.byPixels = byPixels
        result = outcome.result
    }

    public func rows(_ parts: CompareParts) -> [ChangeRow] {
        byPixels ? pixelRows : contentRows.filter { parts.contains($0.part) }.map(\.row)
    }

    /// The new page drawn with ink only it has in green and ink only the old page has in red; nil when the page has no
    /// partner or cannot be drawn.
    public func overlay(_ newPage: Int) async -> PdfRgbaImage? {
        guard let pair = result?.pages.first(where: { $0.newIndex == newPage && !$0.isAdded }) else { return nil }
        let oldRenderer = old.renderer, newRenderer = new.renderer
        return await Task.detached {
            try? PixelComparer.compare(oldRenderer, pair.oldIndex, newRenderer, newPage, pixelDpi)?.overlay
        }.value
    }

    /// The new file with the differences marked, as a job for another thread. It works on documents read again from the
    /// bytes, and gives a protected file back with the protection it had.
    public func reportWork(_ parts: CompareParts, _ fonts: FontSource) -> @Sendable () throws -> [UInt8] {
        let before = before, after = after
        let marked = byPixels ? pixelResult! : ChangeParts.only(result!, parts)
        let oldName = old.title
        let name = byPixels || parts == .all ? new.title : L10n.t("{0} (filtered)", new.title)
        return {
            let first = try before.reopen()
            let second = try after.reopen()
            let report = try ComparisonReport.write(first, second, marked, oldName, name, fonts)
            guard let security = second.security else { return report }
            let plain = try PdfDocument.open(report)
            return try plain.saveRewrite(PdfSaveOptions(security: security, documentId: second.firstId))
        }
    }

    public func dispose() {
        old.dispose()
        new.dispose()
    }

    private nonisolated static func work(_ before: PdfDocument, _ after: PdfDocument, _ oldRenderer: PageRenderer, _ newRenderer: PageRenderer,
                                         _ options: CompareOptions, _ byPixels: Bool, _ token: CancelToken) throws -> Outcome {
        let result = try PdfComparer.compare(before, after, options)
        try token.throwIfCancelled()
        var outcome = Outcome(result: result, rows: result.changes.map { (ChangeParts.of($0), ChangeRow.of($0, before, after)) })
        if byPixels { try comparePixels(&outcome, before, after, oldRenderer, newRenderer, token) }
        return outcome
    }

    private nonisolated static func comparePixels(_ outcome: inout Outcome, _ before: PdfDocument, _ after: PdfDocument,
                                                  _ oldRenderer: PageRenderer, _ newRenderer: PageRenderer, _ token: CancelToken) throws {
        var listed: [ChangeRow] = []
        var changes: [CompareChange] = []
        var added = 0, removed = 0, areas = 0
        for pair in outcome.result.pages {
            try token.throwIfCancelled()
            if pair.isAdded || pair.isRemoved {
                let change = CompareChange(pair.isAdded ? .added : .removed, .page, pair.oldIndex, pair.newIndex, "", "", [], [],
                                           pair.isAdded ? CompareText.pageAdded : CompareText.pageRemoved)
                changes.append(change)
                listed.append(ChangeRow.of(change, before, after))
                if pair.isAdded { added += 1 } else { removed += 1 }
                continue
            }
            guard let found = try PixelComparer.compare(oldRenderer, pair.oldIndex, newRenderer, pair.newIndex, pixelDpi) else {
                outcome.undrawn += 1
                continue
            }
            outcome.looked += 1
            let oldPage = PageGeometry(before.pages[pair.oldIndex])
            let newPage = PageGeometry(after.pages[pair.newIndex])
            areas += found.differences.count
            // A page of scanner noise must not use up the list, so each page gives its largest areas.
            let largest = found.differences.enumerated()
                .sorted { ($0.element.pixels, $1.offset) > ($1.element.pixels, $0.offset) }
                .prefix(rowsPerPage).map(\.element)
                .enumerated()
                .sorted { ($0.element.region.y, $0.element.region.x, $0.offset) < ($1.element.region.y, $1.element.region.x, $1.offset) }
                .map(\.element)
            for difference in largest {
                listed.append(ChangeRow.of(pair, difference, found.alignment, pixelDpi, oldPage, newPage))
            }
            for difference in found.differences.prefix(max(reportMarks - changes.count, 0)) {
                changes.append(pixelChange(pair, difference, newPage))
            }
        }
        outcome.capped = listed.count > pixelRowLimit
        outcome.pixelRows = Array(listed.prefix(pixelRowLimit))
        let summary = ComparisonSummary(added, removed, areas, 0, 0, 0, areas, 0, added + removed, 0, 0, 0)
        outcome.pixelResult = LazyPDFKit.ComparisonResult(outcome.result.pages, changes, summary, outcome.result.oldPageCount, outcome.result.newPageCount)
    }

    private nonisolated static func pixelChange(_ pair: PagePair, _ difference: PixelDifference, _ page: PageGeometry) -> CompareChange {
        let r = difference.region
        let (x0, y0) = page.toUser(r.x, r.y + r.height)
        let (x1, y1) = page.toUser(r.x + r.width, r.y + r.height)
        let (x2, y2) = page.toUser(r.x + r.width, r.y)
        let (x3, y3) = page.toUser(r.x, r.y)
        return CompareChange(.changed, .image, pair.oldIndex, pair.newIndex, "", "", [], [TextQuad(x0, y0, x1, y1, x2, y2, x3, y3)],
                             L10n.t("Looks different"))
    }
}
