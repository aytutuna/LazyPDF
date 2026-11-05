import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/CffInterpreter.cs: a Type 2 charstring interpreter (Adobe TN 5177),
// outline and advance width of one glyph. The C# switch cases with a `when` that fails fall to the default, which
// clears the stack; here each such case does that in an else.

final class CffInterpreter {
    private static let maxDepth = 10
    private static let maxOperators = 200_000

    private let font: CffFont
    private let priv: CffPrivate
    private let widthOnly: Bool
    private let allowSeac: Bool

    private var s = [Double](repeating: 0, count: 96)
    private let out = GlyphOutline()
    private var transient: [Double]?
    private var n = 0
    private var x = 0.0
    private var y = 0.0
    private var pathOpen = false
    private var haveWidth = false
    private var done = false
    private var stems = 0
    private var ops = 0
    private var width: Double

    init(_ font: CffFont, _ priv: CffPrivate, _ widthOnly: Bool, _ allowSeac: Bool) {
        self.font = font
        self.priv = priv
        self.widthOnly = widthOnly
        self.allowSeac = allowSeac
        width = priv.defaultWidth
    }

    func run(_ glyphId: Int) -> CffGlyph {
        exec(font.charString(glyphId), 0)
        endPath()
        return CffGlyph(outline: out, width: width)
    }

    private static func bias(_ count: Int) -> Int {
        count < 1240 ? 107 : count < 33900 ? 1131 : 32768
    }

    private func exec(_ code: FontSpan, _ depth: Int) {
        var p = 0
        while p < code.length && !done {
            ops += 1
            if ops > CffInterpreter.maxOperators {
                done = true
                return
            }
            let b = Int(code[p])
            p += 1
            if b >= 32 || b == 28 {
                let v: Double
                if b == 28 {
                    v = Double(code.i16(p))
                    p += 2
                } else if b <= 246 {
                    v = Double(b - 139)
                } else if b <= 250 {
                    v = Double((b - 247) * 256 + code.u8(p) + 108)
                    p += 1
                } else if b <= 254 {
                    v = Double(-(b - 251) * 256 - code.u8(p) - 108)
                    p += 1
                } else {
                    v = Double(Int32(truncatingIfNeeded: code.u32(p))) / 65536.0
                    p += 4
                }
                if n < s.count {
                    s[n] = v
                    n += 1
                } else {
                    done = true
                }
                continue
            }

            switch b {
            case 1, 3, 18, 23:
                takeWidth((n & 1) == 1)
                stems += n / 2
                n = 0
            case 19, 20:
                takeWidth((n & 1) == 1)
                stems += n / 2
                n = 0
                p += (stems + 7) / 8
            case 21:
                takeWidth(n > 2)
                if n >= 2 { moveTo(s[n - 2], s[n - 1]) }
                n = 0
            case 22:
                takeWidth(n > 1)
                if n >= 1 { moveTo(s[n - 1], 0) }
                n = 0
            case 4:
                takeWidth(n > 1)
                if n >= 1 { moveTo(0, s[n - 1]) }
                n = 0
            case 5:
                var i = 0
                while i + 1 < n {
                    lineTo(s[i], s[i + 1])
                    i += 2
                }
                n = 0
            case 6, 7:
                for i in 0..<n {
                    let horizontal = (i % 2 == 0) == (b == 6)
                    lineTo(horizontal ? s[i] : 0, horizontal ? 0 : s[i])
                }
                n = 0
            case 8:
                var i = 0
                while i + 5 < n {
                    curve(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
                    i += 6
                }
                n = 0
            case 24:
                var i = 0
                while i + 7 < n {
                    curve(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
                    i += 6
                }
                if i + 1 < n { lineTo(s[i], s[i + 1]) }
                n = 0
            case 25:
                var i = 0
                while i + 7 < n {
                    lineTo(s[i], s[i + 1])
                    i += 2
                }
                if i + 5 < n { curve(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]) }
                n = 0
            case 26:
                var i = 0
                var dx1 = 0.0
                if (n & 1) == 1 {
                    dx1 = s[i]
                    i += 1
                }
                while i + 3 < n {
                    curve(dx1, s[i], s[i + 1], s[i + 2], 0, s[i + 3])
                    i += 4
                    dx1 = 0
                }
                n = 0
            case 27:
                var i = 0
                var dy1 = 0.0
                if (n & 1) == 1 {
                    dy1 = s[i]
                    i += 1
                }
                while i + 3 < n {
                    curve(s[i], dy1, s[i + 1], s[i + 2], s[i + 3], 0)
                    i += 4
                    dy1 = 0
                }
                n = 0
            case 30, 31:
                alternatingCurves(b == 31)
                n = 0
            case 10, 29:
                if n == 0 { break }
                let subrs = b == 10 ? priv.subrs : font.globalSubrs
                n -= 1
                let index = FontBytes.toInt32(s[n]) + CffInterpreter.bias(subrs.count)
                if depth < CffInterpreter.maxDepth { exec(subrs.item(font.bytes, index), depth + 1) }
            case 11:
                return
            case 14:
                takeWidth(n == 1 || n == 5)
                if allowSeac && n >= 4 { seac(s[n - 4], s[n - 3], FontBytes.toInt32(s[n - 2]), FontBytes.toInt32(s[n - 1])) }
                n = 0
                done = true
            case 12:
                escape(code.u8(p))
                p += 1
            default:
                n = 0
            }
        }
    }

    private func takeWidth(_ present: Bool) {
        if haveWidth { return }
        haveWidth = true
        if present && n > 0 {
            width = priv.nominalWidth + s[0]
            for i in 0..<(n - 1) { s[i] = s[i + 1] }
            n -= 1
        }
        if widthOnly { done = true }
    }

    private func endPath() {
        if !pathOpen { return }
        out.close()
        pathOpen = false
    }

    private func moveTo(_ dx: Double, _ dy: Double) {
        endPath()
        x += dx
        y += dy
        out.moveTo(x, y)
        pathOpen = true
    }

    private func begin() {
        if pathOpen { return }
        out.moveTo(x, y)
        pathOpen = true
    }

    private func lineTo(_ dx: Double, _ dy: Double) {
        begin()
        x += dx
        y += dy
        out.lineTo(x, y)
    }

    private func curve(_ dx1: Double, _ dy1: Double, _ dx2: Double, _ dy2: Double, _ dx3: Double, _ dy3: Double) {
        begin()
        let x1 = x + dx1
        let y1 = y + dy1
        let x2 = x1 + dx2
        let y2 = y1 + dy2
        x = x2 + dx3
        y = y2 + dy3
        out.cubicTo(x1, y1, x2, y2, x, y)
    }

    private func alternatingCurves(_ horizontalFirst: Bool) {
        var horizontal = horizontalFirst
        var i = 0
        while i + 3 < n {
            let extra = n - i == 5 ? s[i + 4] : 0
            if horizontal {
                curve(s[i], 0, s[i + 1], s[i + 2], extra, s[i + 3])
            } else {
                curve(0, s[i], s[i + 1], s[i + 2], s[i + 3], extra)
            }
            i += 4
            horizontal = !horizontal
        }
    }

    private func seac(_ adx: Double, _ ady: Double, _ baseCode: Int, _ accentCode: Int) {
        endPath()
        append(baseCode, 0, 0)
        append(accentCode, adx, ady)
    }

    private func append(_ standardCode: Int, _ dx: Double, _ dy: Double) {
        guard standardCode >= 0 && standardCode <= 255, let name = StandardNames.standardEncoding[standardCode] else { return }
        let gid = font.glyphForName(name)
        if gid == 0 { return }
        for segment in font.interpret(gid, false, false).outline.segments {
            if segment.op == .close {
                out.add(segment)
            } else {
                var moved = segment
                moved.x += dx
                moved.y += dy
                moved.x1 += dx
                moved.y1 += dy
                moved.x2 += dx
                moved.y2 += dy
                out.add(moved)
            }
        }
    }

    private func escape(_ op: Int) {
        switch op {
        case 35:
            if n >= 12 {
                curve(s[0], s[1], s[2], s[3], s[4], s[5])
                curve(s[6], s[7], s[8], s[9], s[10], s[11])
            }
            n = 0
        case 34:
            if n >= 7 {
                curve(s[0], 0, s[1], s[2], s[3], 0)
                curve(s[4], 0, s[5], -s[2], s[6], 0)
            }
            n = 0
        case 36:
            if n >= 9 {
                curve(s[0], s[1], s[2], s[3], s[4], 0)
                curve(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]))
            }
            n = 0
        case 37:
            if n >= 11 {
                let dx = s[0] + s[2] + s[4] + s[6] + s[8]
                let dy = s[1] + s[3] + s[5] + s[7] + s[9]
                curve(s[0], s[1], s[2], s[3], s[4], s[5])
                if abs(dx) > abs(dy) {
                    curve(s[6], s[7], s[8], s[9], s[10], -dy)
                } else {
                    curve(s[6], s[7], s[8], s[9], -dx, s[10])
                }
            }
            n = 0
        default:
            arithmetic(op)
        }
    }

    private func arithmetic(_ op: Int) {
        switch op {
        case 3, 4, 10, 11, 12, 15, 24, 28:
            if n < 2 {
                n = 0
                return
            }
            n -= 1
            let b = s[n]
            n -= 1
            let a = s[n]
            switch op {
            case 3: push(a != 0 && b != 0 ? 1 : 0)
            case 4: push(a != 0 || b != 0 ? 1 : 0)
            case 10: push(a + b)
            case 11: push(a - b)
            case 12: push(b == 0 ? 0 : a / b)
            case 15: push(a == b ? 1 : 0)
            case 24: push(a * b)
            default:
                push(b)
                push(a)
            }
        case 5, 9, 14, 26, 18, 27, 21, 29:
            if n < 1 {
                n = 0
                return
            }
            n -= 1
            let a = s[n]
            switch op {
            case 5: push(a == 0 ? 1 : 0)
            case 9: push(abs(a))
            case 14: push(-a)
            case 26: push(abs(a).squareRoot())
            case 27:
                push(a)
                push(a)
            case 21:
                if let t = transient, a >= 0, a < Double(t.count) {
                    push(t[FontBytes.toInt32(a)])
                } else {
                    push(0)
                }
            case 29:
                let from = n - 1 - (a < 0 ? 0 : FontBytes.toInt32(min(a, Double(n - 1))))
                push(from >= 0 ? s[from] : 0)
            default:
                break
            }
        case 20:
            if n < 2 {
                n = 0
                return
            }
            n -= 1
            let index = s[n]
            n -= 1
            let value = s[n]
            if transient == nil { transient = [Double](repeating: 0, count: 32) }
            if index >= 0 && index < 32 { transient?[FontBytes.toInt32(index)] = value }
        case 22:
            if n < 4 {
                n = 0
                return
            }
            n -= 1
            let v2 = s[n]
            n -= 1
            let v1 = s[n]
            n -= 1
            let s2 = s[n]
            n -= 1
            let s1 = s[n]
            push(v1 <= v2 ? s1 : s2)
        case 23:
            push(0.5)
        case 30:
            if n < 2 {
                n = 0
                return
            }
            n -= 1
            let j = FontBytes.toInt32(s[n])
            n -= 1
            let count = FontBytes.toInt32(s[n])
            if count <= 0 || count > n { return }
            let top = n - count
            let copy = Array(s[top..<top + count])
            for i in 0..<count {
                // int arithmetic: i + j wraps when j is near the limit.
                let sum = Int(Int32(truncatingIfNeeded: i) &+ Int32(truncatingIfNeeded: j))
                s[top + (sum % count + count) % count] = copy[i]
            }
        default:
            n = 0
        }
    }

    private func push(_ v: Double) {
        if n < s.count {
            s[n] = v
            n += 1
        }
    }
}
