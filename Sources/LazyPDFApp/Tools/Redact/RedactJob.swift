import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/RedactJob.cs: the work behind the panel's buttons, on bytes so that it can run off
// the main actor.

/// A colour the marked places are covered with.
public struct RedactCover: Equatable, Sendable {
    public let name: String
    public let fill: [Double]

    public static var all: [RedactCover] {
        [RedactCover(name: L10n.t("Black"), fill: [0]), RedactCover(name: L10n.t("White"), fill: [1]), RedactCover(name: L10n.t("Gray"), fill: [0.5])]
    }
}

/// A kind of data the finders know by its shape.
public struct RedactDataKind {
    public let name: String
    public let kind: RedactionKind

    public static var all: [RedactDataKind] {
        [
            RedactDataKind(name: L10n.t("Email addresses"), kind: .email),
            RedactDataKind(name: L10n.t("Phone numbers"), kind: .phone),
            RedactDataKind(name: L10n.t("US Social Security numbers"), kind: .usSocialSecurity),
            RedactDataKind(name: L10n.t("Turkish ID numbers"), kind: .turkishId),
            RedactDataKind(name: L10n.t("IBANs"), kind: .iban),
            RedactDataKind(name: L10n.t("Card numbers"), kind: .paymentCard),
            RedactDataKind(name: L10n.t("Dates"), kind: .date),
        ]
    }
}

/// `overlayText` is printed on every marked place; nil for none. `flattenAll` makes every marked page a picture, not only the
/// ones the engine cannot follow.
public struct RedactSettings {
    public let cover: RedactCover
    public let overlayText: String?
    public let flattenAll: Bool

    public init(cover: RedactCover, overlayText: String?, flattenAll: Bool) {
        self.cover = cover
        self.overlayText = overlayText
        self.flattenAll = flattenAll
    }
}

/// `items` is what was found, to be marked; `pictures` the pages with no text to search: scans and drawings, where the finders
/// see nothing.
public struct RedactFound {
    public let items: [MarkItem]
    public let pictures: Int
    /// Pages, 0-based and ascending, where a pattern ran out of time and the page was not searched to its end.
    public var timedOut: [Int] = []
}

public enum RedactJob {
    public static func open(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> PdfDocument {
        try ToolDocuments.open(file, password: password, certificate: certificate)
    }

    public static func find(_ document: PdfDocument, _ kind: RedactDataKind, token: CancelToken = CancelToken()) throws -> RedactFound {
        let cache = TextCache(document)
        let timeouts = SearchTimeouts()
        try token.throwIfCancelled()
        return try gather(document, cache, RedactionFinder.find(cache, kind.kind, timeouts: timeouts),
                          RedactionFinder.findInValues(document, kind.kind), timeouts, token)
    }

    public static func find(_ document: PdfDocument, words: String, matchCase: Bool, wholeWord: Bool,
                            token: CancelToken = CancelToken()) throws -> RedactFound {
        let cache = TextCache(document)
        let timeouts = SearchTimeouts()
        try token.throwIfCancelled()
        return try gather(document, cache, RedactionFinder.findWords(cache, [words], wholeWord, matchCase, timeouts: timeouts),
                          RedactionFinder.findWordsInValues(document, [words], wholeWord, matchCase), timeouts, token)
    }

    /// True when the file lets this opener read it but not change it, so that the engine would refuse to write a copy.
    public static func refuses(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return false }
        return !security.openedAsOwner && security.permissions != .all
    }

    /// Redacts a copy of `file`. `renderer` must draw those same bytes: a page the engine cannot follow to its end is drawn by
    /// it and put back as a picture. The copy has no password, because it opens as a new tab and the window has no password to
    /// give it.
    public static func apply(_ file: [UInt8], password: String?, certificate: X509Certificate?, marks: [RedactionMark], values: [RedactionValueMatch] = [],
                             settings: RedactSettings, renderer: PageRenderer, fonts: FontSource?, images: ImageCodec?,
                             token: CancelToken = CancelToken()) throws -> RedactionResult {
        let document = try open(file, password: password, certificate: certificate)
        try token.throwIfCancelled()
        var options = RedactionOptions()
        options.fill = settings.cover.fill
        options.overlayText = settings.overlayText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        options.changeMetadata = true
        options.renderer = renderer
        options.flattenMarkedPages = settings.flattenAll
        options.keepEncryption = false
        let result = try PdfRedactor(document, fonts, images).apply(marks, options, values)
        try token.throwIfCancelled()
        return result
    }

    public static func failed(_ error: Error) -> Problem {
        let title = L10n.t("Not redacted")
        switch error {
        case is PdfPermissionException:
            return Problem(title, L10n.t("This file does not allow changes. Ask its owner for a copy without limits."))
        case is PdfReadException:
            return Problem(title, L10n.t("The file could not be read. Close it and open it again."))
        case let invalid as InvalidOperationException where invalid.message == RedactionText.noFont:
            return Problem(title, L10n.t("This device has no font for the text on the boxes. Clear that text and try again."))
        default:
            return Problem(title, L10n.t("The redaction could not be finished. Mark fewer places and try again. The file was not changed."))
        }
    }

    public static func clip(_ text: String) -> String {
        let one = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return one.count <= 40 ? one : String(one.prefix(39)) + "…"
    }

    private static func gather(_ document: PdfDocument, _ cache: TextCache, _ matches: [RedactionMatch], _ values: [RedactionValueMatch],
                               _ timeouts: SearchTimeouts, _ token: CancelToken) throws -> RedactFound {
        var pictures = 0
        for page in 0..<document.pages.count {
            try token.throwIfCancelled()
            if cache.get(page).text.allSatisfy(\.isWhitespace) { pictures += 1 }
        }
        return RedactFound(items: matches.map { MarkItem($0.mark, clip($0.text)) } + valueItems(document, values), pictures: pictures,
                           timedOut: Array(Set(timeouts.pages)).sorted())
    }

    // The mark of a value hit is the comment's or field's own rectangle, so that it can be outlined and jumped to.
    private static func valueItems(_ document: PdfDocument, _ values: [RedactionValueMatch]) -> [MarkItem] {
        var items: [MarkItem] = []
        var form: PdfForm?
        let byPage = Dictionary(grouping: values, by: \.page)
        for page in byPage.keys.sorted() {
            let annotations = PdfAnnotations.read(document, document.pages[page])
            for hit in byPage[page]!.sorted(by: { ($0.annotation, $0.start) < ($1.annotation, $1.start) }) {
                let annotation = annotations[hit.annotation]
                var place = L10n.t("Comment on page {0}", hit.page + 1)
                if hit.source == .field {
                    if form == nil { form = PdfForm.read(document) }
                    let name = form?.fields.first { f in f.widgets.contains { $0.dictionary === annotation.dictionary } }?.name ?? ""
                    place = L10n.t("Field {0}, page {1}", name, hit.page + 1)
                }
                items.append(MarkItem(RedactionMark.fromRect(hit.page, annotation.rect), clip(hit.text), value: hit, place: place))
            }
        }
        return items
    }
}

/// What the panel says once a copy is made: the verdict of the check, what was removed, which pages are pictures now.
public struct RedactSummary: Equatable {
    public let clean: Bool
    public let title: String
    public let advice: String
    public let report: String
    public let problems: String
    public let notChecked: String

    public static func of(_ result: RedactionResult, flattenedAll: Bool = false) -> RedactSummary {
        let report = result.report
        let flattened = Set(report.flattened.map { RedactionText.flattened($0) })
        var lines = report.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !flattened.contains($0) }
        if !report.flattened.isEmpty {
            lines.append(L10n.plural(report.flattened.count, one: "Page {1} is now a picture. Its text can no longer be selected.",
                                     other: "Pages {1} are now pictures. Their text can no longer be selected.", pageRanges(report.flattened)))
        }

        let clean = result.verification.isClean
        return RedactSummary(
            clean: clean,
            title: clean ? L10n.t("Check passed") : L10n.t("Check found problems"),
            advice: clean ? L10n.t("Nothing was found inside the marked places. Read what was not checked below before you share it.") : failureAdvice(flattenedAll),
            report: lines.joined(separator: "\n"),
            problems: result.verification.problems.joined(separator: "\n"),
            notChecked: L10n.t("Not checked: the same words in places that are not marked, words inside pictures, and font files."))
    }

    private static func failureAdvice(_ flattenedAll: Bool) -> String {
        flattenedAll
            ? L10n.t("Do not share this copy yet. Read the problems below.")
            : L10n.t("Do not share this copy yet. Read the problems below. Flattening every marked page may clear them.")
    }

    /// Pages from 0 as a person writes them: "2-4, 7".
    public static func pageRanges(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "\(sorted[i] + 1)-\(sorted[j] + 1)" : "\(sorted[i] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }
}
