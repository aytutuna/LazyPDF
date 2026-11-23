#if canImport(SwiftUI)
#if os(iOS)
import UIKit
import LazyPDFApp
import LazyPDFKit

// A page of the viewer for VoiceOver on iPhone and iPad: one element named by its place in the file that reads the page line
// by line from the engine's lines, and on the last page in view asks VoiceOver to turn the page when it has read to the end.
// The Mac twin is PageAccessibility+Mac.swift.

final class PageReadingElement: UIAccessibilityElement, UIAccessibilityReadingContent {
    private weak var view: PageScrollView?
    let page: Int
    private var asked = false

    init(page: Int, view: PageScrollView) {
        self.page = page
        self.view = view
        super.init(accessibilityContainer: view)
        accessibilityLabel = L10n.t("Page {0} of {1}", page + 1, view.viewer.pageCount)
    }

    private var map: PageTextMap? { view?.viewer.textMap(page) }

    // A page that is asked for before its text is read is announced again when the text comes.
    private func read() -> PageTextMap? {
        if let map { return map }
        if !asked, let viewer = view?.viewer {
            asked = true
            let page = page
            Task { @MainActor in await viewer.loadPage(page) }
        }
        return nil
    }

    override var accessibilityValue: String? {
        get { read()?.text }
        set {}
    }

    /// Whether VoiceOver, having read to the end of this element, is to turn the page.
    func turnsPage(_ turns: Bool) {
        accessibilityTraits = turns ? [.staticText, .causesPageTurn] : .staticText
    }

    func textLoaded() {
        guard asked else { return }
        asked = false
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    func accessibilityPageContent() -> String? { read()?.text }

    func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
        guard let map = read(), lineNumber >= 0, lineNumber < map.lineCount else { return nil }
        return map.string(in: map.units(ofLine: lineNumber))
    }

    func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
        guard let view, let map, lineNumber >= 0, lineNumber < map.lineCount,
              let area = view.viewer.textBounds(page: page, map.page.lines[lineNumber].range) else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(CGRect(x: area.x, y: area.y, width: area.width, height: area.height), in: view)
    }

    func accessibilityLineNumber(for point: CGPoint) -> Int {
        guard let view, let map, let screen = view.window?.screen else { return 0 }
        let local = view.convert(point, from: screen.coordinateSpace)
        guard let char = view.viewer.charIndex(page: page, at: ViewPoint(local.x, local.y)), !map.page.chars.isEmpty else { return 0 }
        return map.page.chars[Swift.min(char, map.page.chars.count - 1)].line
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let viewer = view?.viewer else { return false }
        let target: Int
        switch direction {
        case .next: target = page + 1
        case .previous: target = page - 1
        default: return false
        }
        guard target >= 0, target < viewer.pageCount else { return false }
        viewer.goToPage(target)
        UIAccessibility.post(notification: .pageScrolled, argument: L10n.t("Page {0} of {1}", target + 1, viewer.pageCount))
        return true
    }
}
#endif
#endif
