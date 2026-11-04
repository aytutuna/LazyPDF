namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class FormText
{
    public static string NoFont => "No font can draw this text. Choose another font.";

    public static string DynamicXfa => "This is a dynamic XFA form. Lazy PDF cannot fill it.";

    public static string XfaRemoved => "The XFA data was removed. The form now uses its normal fields.";

    public static string ScriptNotRun => "This script did not run. Only built-in format and calculate functions run.";

    public static string NameTaken(string name) => $"A field named {name} already exists. Choose another name.";

    public static string BadName => "A field name cannot be empty or end with a period.";

    public static string BadRect => "The field needs a rectangle with an area.";

    public static string NoPage => "The page is not in the document.";

    public static string NotAField => "This field is not part of the form.";

    public static string KindName(FieldKind kind) => kind switch
    {
        FieldKind.Text => "Text field",
        FieldKind.CheckBox => "Check box",
        FieldKind.Radio => "Radio button",
        FieldKind.PushButton => "Button",
        FieldKind.ComboBox => "Drop-down list",
        FieldKind.ListBox => "List box",
        _ => "Signature",
    };

    public static string OutOfRange(string min, string max) => $"Enter a value from {min} to {max}.";

    public static string AtLeast(string min) => $"Enter a value of at least {min}.";

    public static string AtMost(string max) => $"Enter a value of at most {max}.";

    public static string BadNumber => "Enter a number.";

    public static string BadDate => "Enter a date.";

    public static string BadFormat => "The value does not fit the format.";
}
