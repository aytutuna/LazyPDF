/// The direction a text box takes from what is typed in it: right to left when the first strong character is, as the writers
/// decide it for the saved page.
public enum TextDirection {
    public static func isRightToLeft(_ text: String) -> Bool {
        // The first strong character decides, so a long text only needs its start looked at.
        let start = String(text.prefix(256))
        return start.unicodeScalars.contains { $0.value >= 0x590 } && BidiParagraph(start).level == 1
    }
}
