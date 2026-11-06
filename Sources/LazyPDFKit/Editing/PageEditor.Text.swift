import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageEditor.Text.cs: the changes to the text of a page.

extension PageEditor {
    /// Replaces the characters of a range of `text` (a word, a line, a selection) with `text`, in the same font, size,
    /// colour and spacing and on the same baseline. Characters the font cannot show come from a matching font of the
    /// editor's `FontSource`, reported in the result. Text after the range in the same run moves with it; text in other
    /// runs stays where it is.
    public func replaceText(_ range: TextRange, _ text: String) throws -> TextEditResult {
        try editText("Edit text") { editor in try editor.replace(range, text) }
    }

    /// Takes the text out of a range; what follows in the same run keeps its place.
    public func deleteText(_ range: TextRange) throws -> TextEditResult {
        try editText("Delete text") { editor in try editor.delete(range) }
    }

    /// Adds text before the character `index`, in the font of the glyph it goes next to.
    public func insertText(_ index: Int, _ text: String) throws -> TextEditResult {
        try editText("Insert text") { editor in try editor.insert(index, text) }
    }

    /// Replaces the text of a block: the lines are laid out again inside the width the block had (a single line stays
    /// one line), with the alignment the block shows. Lines the new text does not need are removed; extra lines are
    /// added below, over whatever is there, and the result says the block `grew`. The block takes the style of its first glyph.
    public func replaceParagraph(_ block: TextObject, _ text: String) throws -> TextEditResult {
        try editText("Edit paragraph") { editor in try editor.paragraph(block, text) }
    }

    /// Changes the look of the text of the ranges; see `TextStyleChange`.
    public func setTextStyle(_ ranges: [TextRange], _ change: TextStyleChange) throws -> TextEditResult {
        try editText("Format text") { editor in
            for range in ranges { try editor.restyle(range, change) }
        }
    }

    /// Moves the lines of a block to the left edge, the right edge or the middle of the block, or spreads them over its width.
    public func setAlignment(_ block: TextObject, _ alignment: TextAlignment) throws -> TextEditResult {
        try editText("Align text") { editor in try editor.align(block, alignment) }
    }

    /// Sets the distance between baselines of a block, moving each line from the first by a text rise.
    public func setLineSpacing(_ block: TextObject, _ spacing: Double) throws -> TextEditResult {
        try editText("Line spacing") { editor in try editor.space(block, spacing) }
    }
}
