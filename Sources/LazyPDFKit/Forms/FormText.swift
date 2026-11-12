import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormText.cs: the texts the form layer raises to the user.

public enum FormText {
    public static var noFont: String { L10n.t("No font can draw this text. Choose another font.") }

    public static var dynamicXfa: String { L10n.t("This is a dynamic XFA form. Lazy PDF cannot fill it.") }

    public static var xfaRemoved: String { L10n.t("The XFA data was removed. The form now uses its normal fields.") }

    public static var scriptNotRun: String { L10n.t("This script did not run. Only built-in format and calculate functions run.") }

    public static func nameTaken(_ name: String) -> String { L10n.t("A field named {0} already exists. Choose another name.", name) }

    public static var badName: String { L10n.t("A field name cannot be empty or end with a period.") }

    public static var badRect: String { L10n.t("The field needs a rectangle with an area.") }

    public static var noPage: String { L10n.t("The page is not in the file.") }

    public static var notAField: String { L10n.t("This field is not part of the form.") }

    public static var notSigned: String { L10n.t("This signature field is not signed.") }

    public static var notAButton: String { L10n.t("Only a check box or radio button has an export value.") }

    public static var badExport: String { L10n.t("The export value cannot be empty or Off.") }

    public static func exportTaken(_ value: String) -> String { L10n.t("Another button of this field already uses {0}. Choose another value.", value) }

    public static func unknownFont(_ font: String) -> String { L10n.t("The form has no font named {0}.", font) }

    public static var badSize: String { L10n.t("The text size must be from 0 to 200 points.") }

    public static var badColor: String { L10n.t("A colour is one, three or four numbers from 0 to 1.") }

    public static var notAPushButton: String { L10n.t("Only a button can have an action.") }

    public static var noAddress: String { L10n.t("Type the address the button goes to.") }

    public static func noSuchField(_ name: String) -> String { L10n.t("The form has no field named {0}.", name) }

    public static var otherAction: String { L10n.t("This kind of action cannot be set here.") }

    public static func kindName(_ kind: FieldKind) -> String {
        switch kind {
        case .text: return L10n.t("Text field")
        case .checkBox: return L10n.t("Check box")
        case .radio: return L10n.t("Radio button")
        case .pushButton: return L10n.t("Button")
        case .comboBox: return L10n.t("Drop-down list")
        case .listBox: return L10n.t("List box")
        case .signature: return L10n.t("Signature")
        }
    }

    public static func outOfRange(_ min: String, _ max: String) -> String { L10n.t("Enter a value from {0} to {1}.", min, max) }

    public static func atLeast(_ min: String) -> String { L10n.t("Enter a value of at least {0}.", min) }

    public static func atMost(_ max: String) -> String { L10n.t("Enter a value of at most {0}.", max) }

    public static var badNumber: String { L10n.t("Enter a number.") }

    public static var badDate: String { L10n.t("Enter a date.") }

    public static var badFormat: String { L10n.t("The value does not fit the format.") }
}
