import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Ocr/OcrPages.cs.

/// A page in the list, with what triage found on it.
public struct PageRow: Identifiable, Equatable {
    public let page: Int
    public let kind: OcrPageKind

    public init(_ page: Int, _ kind: OcrPageKind) {
        self.page = page
        self.kind = kind
    }

    public var id: Int { page }

    public var label: String { L10n.t("Page {0}", page + 1) }

    public var kindText: String {
        switch kind {
        case .picture: return L10n.t("Scan|noun")
        case .drawing: return L10n.t("Drawing")
        case .ownLayer: return L10n.t("Searchable")
        case .foreignLayer: return L10n.t("Hidden text")
        case .text: return L10n.t("Has text")
        default: return L10n.t("Blank")
        }
    }

    /// What a screen reader says for the row.
    public var spoken: String { label + ", " + kindText }
}

public enum OcrPages {
    /// Triage of a copy of the file, so it can run while the file is in use.
    public static func classify(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> [OcrPageKind] {
        OcrTriage.classifyAll(try ToolDocuments.open(file, password: password, certificate: certificate))
    }

    /// The pages that need reading first, then the rest, each group in page order.
    public static func rows(_ kinds: [OcrPageKind]) -> [PageRow] {
        kinds.enumerated().map { PageRow($0.offset, $0.element) }
            .sorted { (rank($0.kind), $0.page) < (rank($1.kind), $1.page) }
    }

    /// Whether a page is picked when the list is first shown.
    public static func wanted(_ row: PageRow, replace: Bool) -> Bool {
        OcrTriage.needsOcr(row.kind, replace, false)
    }

    private static func rank(_ kind: OcrPageKind) -> Int {
        switch kind {
        case .picture: return 0
        case .drawing: return 1
        case .foreignLayer: return 2
        case .ownLayer: return 3
        case .text: return 4
        default: return 5
        }
    }
}
