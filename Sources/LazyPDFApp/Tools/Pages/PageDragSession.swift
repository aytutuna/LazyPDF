import Foundation

// The pages a drag in progress carries, for every grid and tab strip in the window. A drag item holds no data of its own
// (PageDrag.type only tells ours from text or files), and the grids of the Pages tool and the organize view are separate
// objects over the same tab, so the pages wait here, where any drop target can read them.

@MainActor
public enum PageDragSession {
    private static var held: PageDragPayload?

    /// The drag in progress; nil when none is, or when its tab is closed.
    public static var current: PageDragPayload? {
        if let held, let tab = held.tab, !tab.isDisposed { return held }
        held = nil
        return nil
    }

    /// A new drag replaces whatever an earlier one left, since a cancelled drag gives no callback.
    public static func begin(_ payload: PageDragPayload) {
        held = payload
    }

    public static func end() {
        held = nil
    }
}
