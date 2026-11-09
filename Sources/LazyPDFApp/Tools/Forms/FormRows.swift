import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormRows.cs.

/// A field in the list: where it is and what kind it is. The ordinal tells apart fields that share a name. Apple's list also
/// shows the state of the field, because a mark on the page is not in the accessibility tree and its row is the way to it.
public struct FieldRow: Equatable, Identifiable {
    public let name: String
    public let hint: String
    public let detail: String
    public let page: Int
    public let index: Int
    public let ordinal: Int
    public let kind: FieldKind
    public let value: String
    public let isOn: Bool
    public let selected: [String]
    public let options: [FieldOption]
    public let canFill: Bool
    public let isRequired: Bool
    public let isSecret: Bool
    public let multiSelect: Bool
    public let isEditable: Bool

    public var id: String { "\(ordinal)#\(name)" }

    /// What the field is for: its hint when the file has one, else its name. Windows names the control by it.
    public var label: String { hint.isEmpty ? name : hint }

    public var summary: String { label + ", " + detail }

    /// The exports of the options a list has chosen, in the order the list shows them.
    public var chosen: [String] {
        options.filter { selected.contains($0.export) || selected.contains($0.display) }.map(\.export)
    }
}

/// A field the detector found, with the box that adds it.
public struct FoundRow: Identifiable {
    public let proposal: FieldProposal
    public var isChecked = true

    public var id: String { "\(proposal.pageIndex)#\(proposal.rect.left)#\(proposal.rect.bottom)#\(proposal.name)" }

    public var text: String { L10n.t("{0}, page {1}", proposal.name, proposal.pageIndex + 1) }
}

public struct KindChoice: Equatable, Hashable {
    public let text: String
    public let kind: FieldKind?
}

public struct TabChoice: Equatable, Hashable {
    public let text: String
    public let order: TabOrder
}

public struct FontChoice: Equatable, Hashable {
    public let text: String
    public let name: String
}

public struct ColourChoice: Equatable, Hashable {
    public let text: String
    public let rgb: [Double]
}

public struct ActionChoice: Equatable, Hashable {
    public let text: String
    public let kind: ButtonActionKind
}

public enum FormChoices {
    public static var kinds: [KindChoice] {
        [KindChoice(text: L10n.t("None"), kind: nil)] + [FieldKind.text, .checkBox, .radio, .pushButton, .comboBox, .listBox, .signature]
            .map { KindChoice(text: FormText.kindName($0), kind: $0) }
    }

    public static var tabOrders: [TabChoice] {
        [TabChoice(text: L10n.t("Order in the file"), order: .annotations), TabChoice(text: L10n.t("By row"), order: .row),
         TabChoice(text: L10n.t("By column"), order: .column)]
    }

    public static let fonts: [FontChoice] = [
        FontChoice(text: "Helvetica", name: "Helv"), FontChoice(text: "Helvetica Bold", name: "HeBo"), FontChoice(text: "Times", name: "TiRo"),
        FontChoice(text: "Times Bold", name: "TiBo"), FontChoice(text: "Courier", name: "Cour"), FontChoice(text: "Courier Bold", name: "CoBo"),
    ]

    public static var colours: [ColourChoice] {
        [ColourChoice(text: L10n.t("Black"), rgb: [0]), ColourChoice(text: L10n.t("Blue"), rgb: [0, 0, 1]),
         ColourChoice(text: L10n.t("Red"), rgb: [1, 0, 0]), ColourChoice(text: L10n.t("Green"), rgb: [0, 0.5, 0]),
         ColourChoice(text: L10n.t("Grey"), rgb: [0.5])]
    }

    public static var actions: [ActionChoice] {
        [ActionChoice(text: L10n.t("No action"), kind: .none), ActionChoice(text: L10n.t("Open a link"), kind: .openLink),
         ActionChoice(text: L10n.t("Reset form"), kind: .reset), ActionChoice(text: L10n.t("Send the form to an address"), kind: .submit),
         ActionChoice(text: L10n.t("Show a field"), kind: .show), ActionChoice(text: L10n.t("Hide a field"), kind: .hide)]
    }

    public static func isFieldAction(_ kind: ButtonActionKind) -> Bool { kind == .show || kind == .hide }

    public static func needsTarget(_ kind: ButtonActionKind) -> Bool { kind == .openLink || kind == .submit || kind == .show || kind == .hide }
}
