import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/OutputChoice.xaml.cs: New file or the same file, under the tools that rewrite the
// whole file.

@MainActor
@Observable
public final class OutputChoice {
    /// True when the result takes the place of the file on disk.
    public var replace = false

    public private(set) var canReplace = false
    public private(set) var isSigned = false
    public private(set) var removesSignatures = false

    public init() {}

    /// `removesSignatures` is whether the tool strips signatures from the result; if not, they stay in it but no longer
    /// check out.
    public func configure(_ tab: DocumentTab, removesSignatures: Bool) {
        isSigned = tab.document.isSigned
        self.removesSignatures = removesSignatures
        canReplace = tab.url != nil && !isSigned
        if !canReplace { replace = false }
    }

    public var signedNote: String {
        removesSignatures ? L10n.t("Signatures are removed from the result.") : L10n.t("Signatures stay in the result but are no longer valid.")
    }

    public var note: String {
        if isSigned { return L10n.t("A signed file is not replaced. The result opens in a new tab.") }
        if !canReplace { return L10n.t("This file is not saved yet.") }
        return replace ? L10n.t("Replaces the file on disk and clears Undo.") : L10n.t("Opens in a new tab. You name it when you save.")
    }
}
