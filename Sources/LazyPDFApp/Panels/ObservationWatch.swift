import Foundation
import Observation

// Stands for the C# DocumentTab.Changed and IDocumentViewer.LayersChanged events, which the observable tab and viewer do
// not raise: a panel watches the properties it rebuilds from.

/// Calls `changed` after what `track` reads has changed, then watches again, until it is stopped.
@MainActor
final class ObservationWatch {
    private let track: @MainActor () -> Void
    private let changed: @MainActor () -> Void
    private var active = true

    init(track: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.track = track
        self.changed = changed
        arm()
    }

    func stop() {
        active = false
    }

    private func arm() {
        guard active else { return }
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            // onChange runs before the new value is stored, so the answer is given one turn later.
            Task { @MainActor in
                guard let self, self.active else { return }
                self.changed()
                self.arm()
            }
        }
    }
}
