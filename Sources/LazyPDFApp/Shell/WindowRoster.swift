import Foundation

/// Which window is the primary, and the moves that wait for a window to open. The primary alone restores the last session,
/// offers the crash leftovers and takes the files Finder hands over, so there is never more than one.
///
/// A window value is the id the scene was opened with. A restored window can come back after a relaunch with an id nobody
/// here knows, and a window opened with no value has none at all; both become the primary when there is none, and are
/// closed at once when there is.
@MainActor
public final class WindowRoster {
    public enum Role: Equatable {
        case primary
        case secondary
        case closed
    }

    private struct Move {
        let tab: DocumentTab
        let from: AppViewModel
        let index: Int
    }

    public private(set) var primary: UUID?
    private var open = Set<UUID>()
    private var moves: [UUID: Move] = [:]

    public init() {}

    /// The id and role of a window that is being shown. The same id asked for again keeps its role.
    public func claim(_ value: UUID?) -> (id: UUID, role: Role) {
        if let value, value == primary {
            open.insert(value)
            return (value, .primary)
        }
        if let value, open.contains(value) { return (value, .secondary) }
        if let value, moves[value] != nil {
            open.insert(value)
            return (value, .secondary)
        }
        // The primary was made before its window, for files that arrived first: this window is the one it waits for.
        if let primary, !open.contains(primary) {
            open.insert(primary)
            return (primary, .primary)
        }
        if primary == nil {
            let id = value ?? UUID()
            primary = id
            open.insert(id)
            return (id, .primary)
        }
        return (value ?? UUID(), .closed)
    }

    /// The primary's id, made now when no window has claimed it: files can arrive before the first window is shown.
    public func reservePrimary() -> UUID {
        if let primary { return primary }
        let id = UUID()
        primary = id
        return id
    }

    /// The window went away. The primary keeps its id, so a window opened with it, or with none, is the primary again.
    public func release(_ id: UUID) {
        open.remove(id)
    }

    /// Notes that `tab` is to go to the window that opens with the returned id.
    public func park(_ tab: DocumentTab, from: AppViewModel, at index: Int) -> UUID {
        let id = UUID()
        moves[id] = Move(tab: tab, from: from, index: index)
        return id
    }

    /// The window opened for a parked move has its view model: the tab goes there if it still can. False when it stays;
    /// nil when no move waits for this window.
    public func arrived(_ id: UUID, _ model: AppViewModel, registry: DocumentRegistry) -> Bool? {
        guard let move = moves.removeValue(forKey: id) else { return nil }
        return registry.transfer(move.tab, from: move.from, to: model, at: move.index)
    }

    /// The window never opened: the tab stays where it is.
    public func forget(_ id: UUID) {
        moves[id] = nil
    }
}
