namespace LazyPDF.Core;

public static class FormText
{
    public static string NoFont => Loc.T("No font can draw this text. Choose another font.");

    public static string DynamicXfa => Loc.T("This is a dynamic XFA form. Lazy PDF cannot fill it.");

    public static string XfaRemoved => Loc.T("The XFA data was removed. The form now uses its normal fields.");

    public static string ScriptNotRun => Loc.T("This script did not run. Only built-in format and calculate functions run.");

    public static string NameTaken(string name) => Loc.T("A field named {0} already exists. Choose another name.", name);

    public static string BadName => Loc.T("A field name cannot be empty or end with a period.");

    public static string BadRect => Loc.T("The field needs a rectangle with an area.");

    public static string NoPage => Loc.T("The page is not in the document.");

    public static string NotAField => Loc.T("This field is not part of the form.");

    public static string NotAButton => Loc.T("Only a check box or radio button has an export value.");

    public static string BadExport => Loc.T("The export value cannot be empty or Off.");

    public static string ExportTaken(string value) => Loc.T("Another button of this field already uses {0}. Choose another value.", value);

    public static string UnknownFont(string font) => Loc.T("The form has no font named {0}.", font);

    public static string BadSize => Loc.T("The text size must be from 0 to 200 points.");

    public static string BadColor => Loc.T("A colour is one, three or four numbers from 0 to 1.");

    public static string NotAPushButton => Loc.T("Only a button can have an action.");

    public static string NoAddress => Loc.T("Type the address the button goes to.");

    public static string NoSuchField(string name) => Loc.T("The form has no field named {0}.", name);

    public static string OtherAction => Loc.T("This kind of action cannot be set here.");

    public static string KindName(FieldKind kind) => kind switch
    {
        FieldKind.Text => Loc.T("Text field"),
        FieldKind.CheckBox => Loc.T("Check box"),
        FieldKind.Radio => Loc.T("Radio button"),
        FieldKind.PushButton => Loc.T("Button"),
        FieldKind.ComboBox => Loc.T("Drop-down list"),
        FieldKind.ListBox => Loc.T("List box"),
        _ => Loc.T("Signature"),
    };

    public static string OutOfRange(string min, string max) => Loc.T("Enter a value from {0} to {1}.", min, max);

    public static string AtLeast(string min) => Loc.T("Enter a value of at least {0}.", min);

    public static string AtMost(string max) => Loc.T("Enter a value of at most {0}.", max);

    public static string BadNumber => Loc.T("Enter a number.");

    public static string BadDate => Loc.T("Enter a date.");

    public static string BadFormat => Loc.T("The value does not fit the format.");
}
