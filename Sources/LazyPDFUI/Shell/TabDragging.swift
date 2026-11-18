#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The Mac's drag of a tab, which can leave the window: a private pasteboard type no other app takes, so a drop on Finder or a
// text field does nothing, and one NSView behind the strip that starts the drag, so the tabs keep their own click, close
// button and menu. The iPhone and iPad keep the String drag of TabStrip.

public struct TabDragEnd {
    /// Where the drag was let go, and the strip's frame, in screen points.
    public let screen: CGPoint
    public let strip: CGRect
    /// A strip of the app accepted the drop.
    public let taken: Bool
    public let escaped: Bool

    public init(screen: CGPoint, strip: CGRect, taken: Bool, escaped: Bool) {
        self.screen = screen
        self.strip = strip
        self.taken = taken
        self.escaped = escaped
    }
}

/// What the strip asks of the shell when a tab is dragged on it or out of it.
public struct TabDragging {
    /// The tab with this id was dropped on the strip, to go before `index`; false when no window has it.
    public var drop: @MainActor (UUID, Int) -> Bool
    /// A drag that began on this strip is over.
    public var ended: @MainActor (DocumentTab, TabDragEnd) -> Void

    public init(drop: @escaping @MainActor (UUID, Int) -> Bool, ended: @escaping @MainActor (DocumentTab, TabDragEnd) -> Void) {
        self.drop = drop
        self.ended = ended
    }
}

struct TabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

extension UTType {
    // Declared as an exported type in the Mac app's Info.plist only.
    static let lazyPdfTab = UTType(exportedAs: "com.alazy.lazypdf.tab")
}

extension NSPasteboard.PasteboardType {
    static let lazyPdfTab = NSPasteboard.PasteboardType("com.alazy.lazypdf.tab")
}

struct TabPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lazyPdfTab)
    }
}

extension View {
    func tabDropTarget(_ dragging: TabDragging?, index: @escaping @MainActor () -> Int,
                       fallback: @escaping @MainActor ([String], Int) -> Bool) -> some View {
        modifier(TabDropTarget(dragging: dragging, index: index, fallback: fallback))
    }

    func reportsTabFrame(of tab: DocumentTab?, in space: String) -> some View {
        background {
            if let tab {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabFrames.self, value: [tab.id: proxy.frame(in: .named(space))])
                }
            }
        }
    }

    func tabDragSource(_ dragging: TabDragging?, frames: [UUID: CGRect], tab: @escaping @MainActor (UUID) -> DocumentTab?) -> some View {
        background {
            if let dragging { TabDragSource(dragging: dragging, frames: frames, tab: tab) }
        }
    }
}

private struct TabDropTarget: ViewModifier {
    let dragging: TabDragging?
    let index: @MainActor () -> Int
    let fallback: @MainActor ([String], Int) -> Bool

    @ViewBuilder func body(content: Content) -> some View {
        if let dragging {
            content.dropDestination(for: TabPayload.self) { items, _ in
                guard let id = items.first?.id else { return false }
                return dragging.drop(id, index())
            }
        } else {
            content.dropDestination(for: String.self) { ids, _ in fallback(ids, index()) }
        }
    }
}

// Not in the hit test: a view that took the mouse-down would keep the drag from the tab's button too. It watches the mouse
// instead, and starts the session when a press on a tab has moved a few points.
private struct TabDragSource: NSViewRepresentable {
    let dragging: TabDragging
    let frames: [UUID: CGRect]
    let tab: @MainActor (UUID) -> DocumentTab?

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        view.update(dragging: dragging, frames: frames, tab: tab)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.update(dragging: dragging, frames: frames, tab: tab)
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) {
        view.stopWatching()
    }

    final class SourceView: NSView, NSDraggingSource {
        private var dragging: TabDragging?
        private var frames: [UUID: CGRect] = [:]
        private var tab: (@MainActor (UUID) -> DocumentTab?)?
        private var monitor: Any?
        private var pressed: (id: UUID, at: CGPoint)?
        private var dragged: DocumentTab?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(dragging: TabDragging, frames: [UUID: CGRect], tab: @escaping @MainActor (UUID) -> DocumentTab?) {
            self.dragging = dragging
            self.frames = frames
            self.tab = tab
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            if window == nil { return }
            let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] (event: NSEvent) -> NSEvent? in
                guard let self else { return event }
                return self.watch(event)
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressed = nil
        }

        // Every event goes on to the tab below, except the drag that starts the session.
        private func watch(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                pressed = nil
                if bounds.contains(point), let hit = frames.first(where: { $0.value.contains(point) }) {
                    pressed = (hit.key, point)
                }
            case .leftMouseDragged:
                guard let held = pressed, hypot(point.x - held.at.x, point.y - held.at.y) > 4 else { return event }
                pressed = nil
                return begin(held.id, event) ? nil : event
            default:
                pressed = nil
            }
            return event
        }

        private func begin(_ id: UUID, _ event: NSEvent) -> Bool {
            guard let tab = tab?(id), let frame = frames[id] else { return false }
            guard let data = try? JSONEncoder().encode(TabPayload(id: id)) else { return false }
            let item = NSPasteboardItem()
            item.setData(data, forType: .lazyPdfTab)
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            dragItem.setDraggingFrame(frame, contents: picture(of: frame))
            dragged = tab
            let session = beginDraggingSession(with: [dragItem], event: event, source: self)
            // The session ends when the drag does, not after the tab has slid back, so the end sees the mouse as it was.
            session.animatesToStartingPositionsOnCancelOrFail = false
            return true
        }

        private func picture(of frame: CGRect) -> NSImage {
            let image = NSImage(size: frame.size)
            guard let content = window?.contentView else { return image }
            let area = convert(frame, to: content)
            if let rep = content.bitmapImageRepForCachingDisplay(in: area) {
                content.cacheDisplay(in: area, to: rep)
                image.addRepresentation(rep)
            }
            return image
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Nothing outside the app takes a tab; a drop there ends with no operation and opens a window.
            context == .withinApplication ? [.copy, .move, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let tab = dragged, let window else { return }
            dragged = nil
            let strip = window.convertToScreen(convert(bounds, to: nil))
            // A drop ends with the button up; Escape ends the drag while it is still down. The key itself is not asked for,
            // which would need Input Monitoring in the sandbox.
            let escaped = NSEvent.pressedMouseButtons & 1 != 0 || NSApp.currentEvent?.type == .keyDown
            dragging?.ended(tab, TabDragEnd(screen: screenPoint, strip: strip, taken: !operation.isEmpty, escaped: escaped))
        }
    }
}
#else
extension View {
    func tabDropTarget(_ dragging: TabDragging?, index: @escaping @MainActor () -> Int,
                       fallback: @escaping @MainActor ([String], Int) -> Bool) -> some View {
        dropDestination(for: String.self) { ids, _ in fallback(ids, index()) }
    }

    func reportsTabFrame(of tab: DocumentTab?, in space: String) -> some View { self }

    func tabDragSource(_ dragging: TabDragging?, frames: [UUID: CGRect], tab: @escaping @MainActor (UUID) -> DocumentTab?) -> some View { self }
}
#endif
#endif
