import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormTypes.cs: the kinds, flags and values the form layer reads and returns.

public enum FieldKind {
    case text, checkBox, radio, pushButton, comboBox, listBox, signature
}

/// The /Ff bits (ISO 32000-1 12.7.3.1, tables 221, 226, 228 and 230).
public struct FieldFlags: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let none = FieldFlags([])
    public static let readOnly = FieldFlags(rawValue: 1)
    public static let required = FieldFlags(rawValue: 1 << 1)
    public static let noExport = FieldFlags(rawValue: 1 << 2)
    public static let multiline = FieldFlags(rawValue: 1 << 12)
    public static let password = FieldFlags(rawValue: 1 << 13)
    public static let noToggleToOff = FieldFlags(rawValue: 1 << 14)
    public static let radio = FieldFlags(rawValue: 1 << 15)
    public static let pushButton = FieldFlags(rawValue: 1 << 16)
    public static let combo = FieldFlags(rawValue: 1 << 17)
    public static let edit = FieldFlags(rawValue: 1 << 18)
    public static let sort = FieldFlags(rawValue: 1 << 19)
    public static let fileSelect = FieldFlags(rawValue: 1 << 20)
    public static let multiSelect = FieldFlags(rawValue: 1 << 21)
    public static let doNotSpellCheck = FieldFlags(rawValue: 1 << 22)
    public static let doNotScroll = FieldFlags(rawValue: 1 << 23)
    public static let comb = FieldFlags(rawValue: 1 << 24)
    /// Rich text for a text field, radios in unison for a radio group: the same bit.
    public static let richText = FieldFlags(rawValue: 1 << 25)
    public static let commitOnSelectionChange = FieldFlags(rawValue: 1 << 26)
}

/// An /Opt entry: the value stored and the text shown.
public struct FieldOption: Equatable {
    public let export: String
    public let display: String

    public init(_ export: String, _ display: String) {
        self.export = export
        self.display = display
    }

    public init(_ both: String) {
        self.init(both, both)
    }
}

/// The page /Tabs entry (ISO 32000-1 12.5.2): the order Tab visits the widgets of a page.
public enum TabOrder {
    /// No /Tabs entry: the order of /Annots.
    case annotations
    case row, column, structure
}

public enum XfaKind {
    case none
    /// An XFA form with an AcroForm behind it, which can be filled through the AcroForm.
    case `static`
    /// An XFA form that exists only as XFA; there is nothing here to fill.
    case dynamic
}

/// One field read from the form: the merged field and widget entries, with inherited values resolved.
public final class FormField {
    init(_ dictionary: PdfDictionary, _ reference: PdfReference?, _ name: String, _ partialName: String, _ kind: FieldKind, _ flags: FieldFlags) {
        self.dictionary = dictionary
        self.reference = reference
        self.name = name
        self.partialName = partialName
        self.kind = kind
        self.flags = flags
    }

    /// The terminal field dictionary, live; a merged field and widget is also its widget's dictionary.
    public let dictionary: PdfDictionary
    public let reference: PdfReference?

    /// The fully qualified name: the partial names from the root, joined by periods.
    public let name: String
    public let partialName: String
    public let kind: FieldKind
    public let flags: FieldFlags

    /// The value as text. For a check box or radio group it is the export value of the chosen button,
    /// or "Off"; for a list with several choices the first one (see `selected`); nil when none is set.
    public internal(set) var value: String?
    public internal(set) var selected: [String] = []
    public internal(set) var defaultValue: String?
    public internal(set) var defaultAppearance: String?
    public internal(set) var alignment = 0

    /// /MaxLen, 0 when there is none.
    public internal(set) var maxLength = 0
    public internal(set) var options: [FieldOption] = []
    public internal(set) var tooltip: String?
    public internal(set) var widgets: [FormWidget] = []

    /// The widget is on a page but its field is not reachable from /AcroForm /Fields.
    public internal(set) var isOrphan = false

    public var isChecked: Bool {
        (kind == .checkBox || kind == .radio) && value != nil && value != "Off"
    }

    /// A signature field that holds a signature (/V is set). Nothing here checks it.
    public var isSigned: Bool { kind == .signature && dictionary["V"] != nil }

    public func has(_ flag: FieldFlags) -> Bool { flags.contains(flag) }
}

/// A widget annotation of a field.
public final class FormWidget {
    init(_ dictionary: PdfDictionary, _ reference: PdfReference?, _ pageIndex: Int, _ rect: PdfRect, _ onState: String?, _ export: String?) {
        self.dictionary = dictionary
        self.reference = reference
        self.pageIndex = pageIndex
        self.rect = rect
        self.onState = onState
        self.export = export
    }

    public let dictionary: PdfDictionary
    public let reference: PdfReference?

    /// The page index, -1 for a widget no page lists.
    public let pageIndex: Int
    public let rect: PdfRect

    /// The name of the appearance state that means "on" (check boxes and radios), nil without one.
    public let onState: String?

    /// The value this button stands for: the /Opt text when the field has one, else the state name.
    public let export: String?
    public internal(set) var isOn = false
    public internal(set) weak var field: FormField?
}

/// Which widgets `PdfForm.setValues` filled and what it could not place. `filled` counts the fields given a value (a name
/// shared by several fields counts each); `unknownFields` are names no field has; `rejected` names whose value does not
/// fit the field (an unknown radio choice, a button, a signature); `calculated` the fields the calculation order changed
/// afterwards; `notRun` the scripts that were not run because they are not built-in functions.
public struct FormFillResult {
    public let filled: Int
    public let unknownFields: [String]
    public let rejected: [String]
    public let calculated: Int
    public let notRun: [FormScript]
    public let undrawn: String

    public init(_ filled: Int, _ unknownFields: [String], _ rejected: [String], _ calculated: Int, _ notRun: [FormScript], _ undrawn: String = "") {
        self.filled = filled
        self.unknownFields = unknownFields
        self.rejected = rejected
        self.calculated = calculated
        self.notRun = notRun
        self.undrawn = undrawn
    }
}

/// The font name (a /DR name such as Helv), size in points (0 fits the text to the field) and colour a field's /DA gives.
public struct TextLook {
    public let font: String
    public let size: Double
    public let color: [Double]

    public init(_ font: String, _ size: Double, _ color: [Double]) {
        self.font = font
        self.size = size
        self.color = color
    }
}

public enum ButtonActionKind {
    case none, openLink, reset, submit, show, hide

    /// An action this layer does not write: a script, a page jump and the like. Reading gives it; setting it is refused.
    case other
}

/// What a push button does when it is clicked. `target` is the address of a link or a submit, and the full name of the
/// field a Show or Hide acts on.
public struct ButtonAction {
    public let kind: ButtonActionKind
    public let target: String?

    public init(_ kind: ButtonActionKind, _ target: String? = nil) {
        self.kind = kind
        self.target = target
    }
}

// Field names and option values are text the C# compares ordinally, unit by unit. Swift's == and hasPrefix go by canonical
// equivalence, which would make two names that differ only in how an accent is written one field.
extension String {
    func equalsOrdinal(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }

    func hasPrefixOrdinal(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }

    /// Split at periods into at most `limit` parts, the last holding the rest.
    func splitPeriods(_ limit: Int = Int.max) -> [String] {
        var parts: [String] = []
        var current: [UInt16] = []
        for unit in utf16 {
            if unit == 0x2E && parts.count < limit - 1 {
                parts.append(String(decoding: current, as: UTF16.self))
                current = []
            } else {
                current.append(unit)
            }
        }
        parts.append(String(decoding: current, as: UTF16.self))
        return parts
    }
}

extension Array where Element == String {
    func containsOrdinal(_ text: String) -> Bool { contains { $0.equalsOrdinal(text) } }
}
