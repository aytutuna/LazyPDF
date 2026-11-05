import Foundation

// Twin of windows/LazyPDF.Core/Forms/FieldSpec.cs: a field to add with `PdfForm.addField`: where it goes and how it looks.
// Colours are 1, 3 or 4 numbers from 0 to 1; a nil colour paints nothing. Flags that name the kind (radio, push button,
// combo) are set by `kind`.

public struct FieldSpec {
    public var kind: FieldKind
    public var name: String
    public var pageIndex: Int
    public var rect: PdfRect
    public var value: String?
    public var defaultValue: String?

    /// The choices of a combo or list box.
    public var options: [FieldOption]?

    /// Required, read only, multiline, password, comb, multi-select, editable combo and the like.
    public var flags: FieldFlags
    public var maxLength: Int
    public var tooltip: String?

    /// The name of a font in /DR; Helv is added when the form has none.
    public var font: String

    /// In points; 0 fits the text to the field.
    public var fontSize: Double
    public var textColor: [Double]
    public var borderColor: [Double]?
    public var background: [Double]?
    public var borderWidth: Double
    public var borderStyle: BorderStyle

    /// 0 left, 1 centred, 2 right.
    public var alignment: Int

    /// Turns the widget by 0, 90, 180 or 270 degrees (/MK /R).
    public var rotation: Int

    /// The caption of a push button, or the mark of a check box or radio button (a ZapfDingbats character: 4 check, 8 cross,
    /// l circle, n square, u diamond, H star).
    public var caption: String?

    /// What a check box or the first radio button exports; "Yes" and "Choice1" when nil.
    public var exportValue: String?

    public init(_ kind: FieldKind, _ name: String, _ pageIndex: Int, _ rect: PdfRect, value: String? = nil,
                defaultValue: String? = nil, options: [FieldOption]? = nil, flags: FieldFlags = .none, maxLength: Int = 0,
                tooltip: String? = nil, font: String = "Helv", fontSize: Double = 0, textColor: [Double] = [0],
                borderColor: [Double]? = [0], background: [Double]? = nil, borderWidth: Double = 1,
                borderStyle: BorderStyle = .solid, alignment: Int = 0, rotation: Int = 0, caption: String? = nil,
                exportValue: String? = nil) {
        self.kind = kind
        self.name = name
        self.pageIndex = pageIndex
        self.rect = rect
        self.value = value
        self.defaultValue = defaultValue
        self.options = options
        self.flags = flags
        self.maxLength = maxLength
        self.tooltip = tooltip
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.borderColor = borderColor
        self.background = background
        self.borderWidth = borderWidth
        self.borderStyle = borderStyle
        self.alignment = alignment
        self.rotation = rotation
        self.caption = caption
        self.exportValue = exportValue
    }
}
