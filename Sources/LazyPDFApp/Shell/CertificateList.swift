import Foundation
import Observation
import LazyPDFKit

// The identities the person has imported from .p12 files, with a way to import more and to delete them. Only the iPhone and
// iPad keep imported identities in the app's own keychain; the Mac and Windows use the system's store.

@MainActor
@Observable
public final class CertificateListModel {
    public private(set) var items: [CertificateChoice] = []
    public private(set) var note = ""

    @ObservationIgnored private let list: @MainActor () -> [CertificateChoice]
    @ObservationIgnored private let delete: @MainActor (CertificateChoice) -> Bool
    @ObservationIgnored private let add: @MainActor () async -> CertificateChoice?

    /// `delete` says whether the identity is gone; `add` imports one and returns nil when the person gave up.
    public init(list: @escaping @MainActor () -> [CertificateChoice], delete: @escaping @MainActor (CertificateChoice) -> Bool,
                add: @escaping @MainActor () async -> CertificateChoice?) {
        self.list = list
        self.delete = delete
        self.add = add
        reload()
    }

    public func reload() {
        items = list()
    }

    public func importOne() async {
        note = ""
        _ = await add()
        reload()
    }

    public func remove(at offsets: IndexSet) {
        note = ""
        for choice in offsets.compactMap({ items.indices.contains($0) ? items[$0] : nil }) where !delete(choice) {
            note = L10n.t("The certificate could not be removed.")
        }
        reload()
    }
}
