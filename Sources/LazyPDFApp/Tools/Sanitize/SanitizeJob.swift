import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Sanitize/SanitizeJob.cs. The work is done on a copy of the file's bytes, so it can run
// off the main actor while the document stays as it is.

public enum SanitizeJob {
    public static func scan(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> [SanitizeFinding] {
        let document = try ToolDocuments.open(file, password: password, certificate: certificate)
        return try PdfSanitizer(document).scan()
    }

    public static func run(_ file: [UInt8], password: String?, certificate: X509Certificate?, ticked: Set<SanitizeItem>,
                           token: CancelToken) throws -> SanitizeResult {
        let document = try ToolDocuments.open(file, password: password, certificate: certificate)
        let result = try PdfSanitizer(document).run(options(ticked))
        try token.throwIfCancelled()
        return result
    }

    public static func options(_ ticked: Set<SanitizeItem>) -> SanitizeOptions {
        SanitizeOptions(
            javaScript: ticked.contains(.javaScript), launchActions: ticked.contains(.launchActions),
            embeddedFiles: ticked.contains(.embeddedFiles), hiddenLayers: ticked.contains(.hiddenLayers),
            invisibleText: ticked.contains(.invisibleText), comments: ticked.contains(.comments),
            formData: ticked.contains(.formData), metadata: ticked.contains(.metadata), pieceInfo: ticked.contains(.pieceInfo),
            thumbnails: ticked.contains(.thumbnails), searchIndexes: ticked.contains(.searchIndexes),
            externalLinks: ticked.contains(.externalLinks), filePaths: ticked.contains(.filePaths))
    }

    /// "Comments and markup (14)" for each item, joined.
    public static func list(_ items: [SanitizeFinding]) -> String {
        items.map { L10n.t("{0} ({1})", OptimizeText.itemName($0.item), $0.count) }.joined(separator: "; ")
    }
}

/// One thing the scan found. Some can be switched off; the rest are always removed or only reported.
public struct SanitizeRow: Identifiable, Equatable {
    public let item: SanitizeItem
    public let count: Int

    /// Hidden text is only reported, and invisible text may be the text layer of a scan, so it starts off.
    public var isChecked: Bool

    public init(_ finding: SanitizeFinding) {
        item = finding.item
        count = finding.count
        isChecked = finding.item != .hiddenText && finding.item != .invisibleText
    }

    public var id: Int { item.rawValue }

    public var label: String { L10n.t("{0} ({1})", OptimizeText.itemName(item), count) }

    public var canTick: Bool { item != .hiddenText && item != .previousVersions && item != .signatures }

    public var note: String {
        switch item {
        case .hiddenText: return L10n.t("Only reported. Redact removes it.")
        case .invisibleText: return L10n.t("May be the text layer of a scan. Off unless you tick it.")
        case .previousVersions, .signatures: return L10n.t("Always removed.")
        default: return ""
        }
    }
}
