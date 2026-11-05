import Foundation

// Twin of windows/LazyPDF.Core/Structure/StructureText.cs: the words the structure layer shows.

public enum StructureText {
    public static var newBookmark: String { L10n.t("New bookmark") }

    public static var unnamedLayer: String { L10n.t("Layer") }

    public static func formKindName(_ kind: FormKind) -> String {
        switch kind {
        case .acroForm: return L10n.t("Form")
        case .xfa: return L10n.t("XFA form")
        case .none: return L10n.t("None")
        }
    }
}
