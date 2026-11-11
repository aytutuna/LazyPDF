/// One two-finger swipe on a trackpad, summed until it is long enough to turn a page.
struct PageSwipe {
    private var sumX = 0.0
    private var sumY = 0.0
    private var fired = false

    /// -1 for the previous page, 1 for the next, once per gesture; nil while it is short, mostly vertical or already used.
    mutating func add(dx: Double, dy: Double, began: Bool, ended: Bool) -> Int? {
        if began { reset() }
        defer { if ended { reset() } }
        if fired { return nil }
        sumX += dx
        sumY += dy
        guard abs(sumX) >= 80, abs(sumX) > 2 * abs(sumY) else { return nil }
        fired = true
        return sumX > 0 ? -1 : 1
    }

    private mutating func reset() {
        sumX = 0
        sumY = 0
        fired = false
    }
}
