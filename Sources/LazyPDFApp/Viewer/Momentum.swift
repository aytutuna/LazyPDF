import Foundation

/// The glide of a page after a finger lifts, at the system's rate of 0.998 per millisecond.
public struct Momentum {
    private var velocity: ViewPoint

    /// nil under 200 points a second, which is a finger at rest.
    public init?(velocity: ViewPoint) {
        guard hypot(velocity.x, velocity.y) >= 200 else { return nil }
        self.velocity = velocity
    }

    /// The distance to move over `dt` seconds, nil once the glide is slower than 20 points a second.
    public mutating func step(_ dt: Double) -> ViewPoint? {
        let slowing = pow(0.998, dt * 1000)
        velocity = ViewPoint(velocity.x * slowing, velocity.y * slowing)
        guard hypot(velocity.x, velocity.y) >= 20 else { return nil }
        return ViewPoint(velocity.x * dt, velocity.y * dt)
    }
}
