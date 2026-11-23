#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import LazyPDFApp
import LazyPDFKit

// A page of the viewer for VoiceOver on the Mac: a group named by its place in the file, holding one static text element
// with the page's text, so VoiceOver can read it by line and word and move the viewer's selection. The Windows twin is
// windows/LazyPDF.App/Viewer/PageTextProvider.cs and PageTextRange.cs, which also reach across pages; here an element is a page.

final class PageAccessibilityGroup: NSAccessibilityElement {
    let text: PageTextElement

    init(page: Int, view: PageDocumentView) {
        text = PageTextElement(page: page, view: view)
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Page {0} of {1}", page + 1, view.viewer.pageCount))
        text.setAccessibilityParent(self)
    }

    override func accessibilityChildren() -> [Any]? { [text] }
}

final class PageTextElement: NSAccessibilityElement {
    private weak var view: PageDocumentView?
    private let page: Int
    private var reported = NSRange(location: NSNotFound, length: 0)

    init(page: Int, view: PageDocumentView) {
        self.page = page
        self.view = view
        super.init()
    }

    private var viewer: ViewerModel? { view?.viewer }
    private var map: PageTextMap? { viewer?.textMap(page) }

    private static func units(_ range: NSRange) -> Range<Int> {
        guard range.location != NSNotFound, range.location >= 0 else { return 0..<0 }
        return range.location..<(range.location + Swift.max(range.length, 0))
    }

    private static func range(_ units: Range<Int>) -> NSRange {
        NSRange(location: units.lowerBound, length: units.count)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityValue() -> Any? { map?.text }

    override func accessibilityFrame() -> NSRect {
        guard let view, let viewer, let matrix = viewer.pageToView(page) else { return .zero }
        let size = viewer.pageSize(page)
        return view.screenRect(PageSpace.transform(matrix, ViewRect(0, 0, size.width, size.height)))
    }

    override func accessibilityNumberOfCharacters() -> Int { map?.length ?? 0 }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let map else { return NSRange(location: 0, length: 0) }
        guard let lines = viewer?.visibleLines(on: page) else { return NSRange(location: 0, length: map.length) }
        let from = map.units(ofLine: lines.lowerBound).lowerBound
        return Self.range(from..<Swift.max(map.units(ofLine: lines.upperBound).upperBound, from))
    }

    // Nothing selected on the page has no place; the caret is not kept apart from the selection.
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let map, let chars = viewer?.selectedChars(on: page) else { return NSRange(location: NSNotFound, length: 0) }
        return Self.range(map.units(of: chars))
    }

    override func accessibilitySelectedText() -> String? {
        guard let map, let chars = viewer?.selectedChars(on: page) else { return nil }
        return map.string(in: map.units(of: chars))
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let map, let viewer, range.location != NSNotFound else { return }
        viewer.select(page: page, map.chars(in: Self.units(range)))
    }

    override func accessibilityString(for range: NSRange) -> String? {
        map?.string(in: Self.units(range))
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let map else { return NSRange(location: 0, length: 0) }
        return Self.range(map.units(ofLine: line))
    }

    override func accessibilityLine(for index: Int) -> Int {
        map?.line(atOffset: index) ?? 0
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard let map, index >= 0, index < map.length else { return NSRange(location: map?.length ?? 0, length: 0) }
        let chars = map.chars(in: index..<(index + 1))
        let found = map.units(of: chars)
        return found.contains(index) ? Self.range(found) : NSRange(location: index, length: 1)
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let view, let viewer, let map, let char = viewer.charIndex(page: page, at: view.viewPoint(fromScreen: point)) else {
            return NSRange(location: 0, length: 0)
        }
        return Self.range(map.units(ofChar: char))
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let view, let viewer, let map else { return .zero }
        let chars = map.chars(in: Self.units(range))
        guard let area = viewer.textBounds(page: page, chars) else { return .zero }
        return view.screenRect(area)
    }

    /// Tells VoiceOver when the selection on the page is not the one it was last told of.
    func selectionMayHaveChanged() {
        let now = accessibilitySelectedTextRange()
        guard now != reported else { return }
        reported = now
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    func textLoaded() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
#endif
#endif
