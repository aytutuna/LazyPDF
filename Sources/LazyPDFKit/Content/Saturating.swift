import Foundation

// No twin. A C# (int) or (long) cast of a double saturates and turns NaN into 0; Swift's Int(_:) traps on both.
// Math.Min and Math.Max of a NaN give NaN; Swift.min and Swift.max skip it, and which one wins depends on the order.

extension Int {
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 9.2233720368547758e18 {
            self = Int.max
        } else if value <= -9.2233720368547758e18 {
            self = Int.min
        } else {
            self = Int(value)
        }
    }

    /// The same for a C# (int) cast: saturated to the Int32 range.
    init(saturating32 value: Double) {
        self = Swift.min(Swift.max(Int(saturating: value), Int(Int32.min)), Int(Int32.max))
    }
}

func nanMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? Double.nan : Swift.min(a, b) }

func nanMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? Double.nan : Swift.max(a, b) }
