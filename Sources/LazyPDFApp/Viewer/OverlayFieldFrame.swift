import Foundation

// Where the page view puts the text control of an OverlayField. The control is upright whatever the viewer's rotation, so it
// is the size of the field's area times the scale, centred on where the turned area lands, and not the bounding box of that.

enum OverlayFieldFrame {
    /// The frame in the viewer's view. `used` is the room the text takes at the control's width; the frame grows to hold it,
    /// downwards for every field and to the right as well for one that does not wrap.
    static func of(_ area: ViewRect, _ matrix: ViewMatrix, used: ViewSize?, wraps: Bool) -> ViewRect {
        let scale = ViewScale.of(matrix)
        let turned = PageSpace.transform(matrix, area)
        let width = area.width * scale
        let height = area.height * scale
        let x = turned.x + (turned.width - width) / 2
        let y = turned.y + (turned.height - height) / 2
        guard let used else { return ViewRect(x, y, width, height) }
        return ViewRect(x, y, wraps ? width : Swift.max(width, used.width), Swift.max(height, used.height))
    }
}
