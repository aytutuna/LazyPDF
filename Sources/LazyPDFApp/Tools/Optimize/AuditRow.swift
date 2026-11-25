import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/AuditRow.cs: one line of "where the space goes", a kind of data, its bytes and
// its share of the file.

public struct AuditRow: Identifiable, Equatable {
    public let kind: SpaceKind
    public let bytes: Int
    public let share: Double

    public init(kind: SpaceKind, bytes: Int, share: Double) {
        self.kind = kind
        self.bytes = bytes
        self.share = share
    }

    public var id: Int { kind.rawValue }

    public var name: String { OptimizeText.kindName(kind) }

    public var size: String { SizeText.of(bytes) }

    public var summary: String { L10n.t("{0}, {1}", name, size) }

    /// The kinds that hold any bytes, the biggest first.
    public static func of(_ audit: SpaceAudit) -> [AuditRow] {
        audit.bytes.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .map { AuditRow(kind: $0.key, bytes: $0.value, share: audit.fileSize > 0 ? Double($0.value) / Double(audit.fileSize) : 0) }
    }
}
