import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/Type1Interpreter.cs: a Type 1 charstring interpreter, outline and
// advance width of one glyph, flex and seac included.

final class Type1Interpreter {
    private static let maxDepth = 10
    private static let maxOperators = 200_000

    private let font: Type1Font
    private let allowSeac: Bool

    private var s = [Double](repeating: 0, count: 64)
    private var ps: [Double] = []
    private var flex: [(x: Double, y: Double)] = []
    private let out = GlyphOutline()
    private var n = 0
    private var x = 0.0
    private var y = 0.0
    private var sbx = 0.0
    private var width = 0.0
    private var pathOpen = false
    private var flexing = false
    private var done = false
    private var ops = 0

    init(_ font: Type1Font, _ allowSeac: Bool) {
        self.font = font
        self.allowSeac = allowSeac
    }

    func run(_ name: String) -> Type1Glyph {
        if let code = font.charString(name) { exec(code, 0) }
        close()
        return Type1Glyph(outline: out, width: width)
    }

    private func exec(_ bytes: [UInt8], _ depth: Int) {
        let code = FontSpan(bytes)
        var p = 0
        while p < code.length && !done {
            ops += 1
            if ops > Type1Interpreter.maxOperators {
                done = true
                return
            }
            let b = Int(code[p])
            p += 1
            if b >= 32 {
                let v: Double
                if b <= 246 {
                    v = Double(b - 139)
                } else if b <= 250 {
                    v = Double((b - 247) * 256 + code.u8(p) + 108)
                    p += 1
                } else if b <= 254 {
                    v = Double(-(b - 251) * 256 - code.u8(p) - 108)
                    p += 1
                } else {
                    v = Double(Int32(truncatingIfNeeded: code.u32(p)))
                    p += 4
                }
                push(v)
                continue
            }

            switch b {
            case 13 where n >= 2:
                sbx = s[0]
                width = s[1]
                x = sbx
                y = 0
                n = 0
            case 4 where n >= 1:
                moveTo(0, s[n - 1])
                n = 0
            case 21 where n >= 2:
                moveTo(s[n - 2], s[n - 1])
                n = 0
            case 22 where n >= 1:
                moveTo(s[n - 1], 0)
                n = 0
            case 5 where n >= 2:
                lineTo(s[0], s[1])
                n = 0
            case 6 where n >= 1:
                lineTo(s[0], 0)
                n = 0
            case 7 where n >= 1:
                lineTo(0, s[0])
                n = 0
            case 8 where n >= 6:
                curve(s[0], s[1], s[2], s[3], s[4], s[5])
                n = 0
            case 30 where n >= 4:
                curve(0, s[0], s[1], s[2], s[3], 0)
                n = 0
            case 31 where n >= 4:
                curve(s[0], 0, s[1], s[2], 0, s[3])
                n = 0
            case 9:
                close()
                n = 0
            case 10 where n >= 1:
                n -= 1
                let index = FontBytes.toInt32(s[n])
                if depth < Type1Interpreter.maxDepth && index >= 0 && index < font.subrs.count, let sub = font.subrs[index] {
                    exec(sub, depth + 1)
                }
            case 11:
                return
            case 14:
                done = true
            case 12:
                escape(code.u8(p))
                p += 1
            default:
                n = 0
            }
        }
    }

    private func escape(_ op: Int) {
        switch op {
        case 6 where n >= 5 && allowSeac:
            seac(s[0], s[1], s[2], FontBytes.toInt32(s[3]), FontBytes.toInt32(s[4]))
            n = 0
            done = true
        case 7 where n >= 4:
            sbx = s[0]
            width = s[2]
            x = sbx
            y = s[1]
            n = 0
        case 12 where n >= 2:
            n -= 1
            let d = s[n]
            n -= 1
            let a = s[n]
            push(d == 0 ? 0 : a / d)
        case 16 where n >= 2:
            callOtherSubr()
        case 17:
            if let last = ps.popLast() { push(last) }
        case 33 where n >= 2:
            x = s[0]
            y = s[1]
            n = 0
        default:
            n = 0
        }
    }

    private func callOtherSubr() {
        n -= 1
        let which = FontBytes.toInt32(s[n])
        n -= 1
        var count = FontBytes.toInt32(s[n])
        if count < 0 || count > n { count = n }

        switch which {
        case 1:
            flexing = true
            flex.removeAll()
            n -= count
        case 2:
            if flexing { flex.append((x, y)) }
            n -= count
        case 0 where count >= 3:
            let ey = s[n - 1]
            let ex = s[n - 2]
            n -= count
            flexing = false
            if flex.count >= 7 {
                begin()
                for k in [1, 4] {
                    out.cubicTo(flex[k].x, flex[k].y, flex[k + 1].x, flex[k + 1].y, flex[k + 2].x, flex[k + 2].y)
                }
                x = flex[6].x
                y = flex[6].y
            }
            ps.append(ey)
            ps.append(ex)
        default:
            // Hint replacement (3) and unknown routines hand their arguments back through pop.
            for _ in 0..<count {
                n -= 1
                ps.append(s[n])
            }
        }
    }

    private func seac(_ asb: Double, _ adx: Double, _ ady: Double, _ baseCode: Int, _ accentCode: Int) {
        close()
        append(baseCode, 0, 0)
        append(accentCode, sbx - asb + adx, ady)
    }

    private func append(_ code: Int, _ dx: Double, _ dy: Double) {
        guard code >= 0 && code <= 255, let name = StandardNames.standardEncoding[code] else { return }
        guard let glyph = font.run(name, false) else { return }
        for segment in glyph.outline.segments {
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

    private func push(_ v: Double) {
        if n < s.count {
            s[n] = v
            n += 1
        } else {
            done = true
        }
    }

    private func close() {
        if !pathOpen { return }
        out.close()
        pathOpen = false
    }

    private func begin() {
        if pathOpen { return }
        out.moveTo(x, y)
        pathOpen = true
    }

    private func moveTo(_ dx: Double, _ dy: Double) {
        x += dx
        y += dy
        if flexing { return }
        close()
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
}
