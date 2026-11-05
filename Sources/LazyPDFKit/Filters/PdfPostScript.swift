import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfPostScript.cs: type 4 functions (ISO 32000-1 7.10.5), a subset of
// PostScript with no loops, so a program runs in time proportional to its size.

extension PdfFunction {
    final class PostScript: PdfFunction {
        private static let stackSize = 100, maxNesting = 32

        private enum Code: String, CaseIterable {
            case push, abs, add, atan, ceiling, cos, cvi, cvr, div, exp, floor, idiv, ln, log, mod, mul, neg, round, sin, sqrt, sub, truncate
            case and, bitshift, eq, `false`, ge, gt, le, lt, ne, not, or, `true`, xor
            case copy, dup, exch, index, pop, roll, `if`, ifElse = "ifelse"
        }

        private struct Op {
            var code: Code
            var value = 0.0
            var body: [Op]?
            var otherwise: [Op]?

            init(_ code: Code, _ value: Double = 0, body: [Op]? = nil, otherwise: [Op]? = nil) {
                self.code = code
                self.value = value
                self.body = body
                self.otherwise = otherwise
            }
        }

        private struct Value {
            var number = 0.0
            var isBoolean = false
        }

        private static let words: [String: Code] = {
            var words: [String: Code] = [:]
            for code in Code.allCases where code != .push && code != .if && code != .ifElse { words[code.rawValue] = code }
            return words
        }()

        private var program: [Op] = []

        static func create(_ stream: PdfStream?, _ domain: [Double], _ range: [Double]?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws -> PostScript {
            guard let stream, let range, range.count >= 2 else {
                throw PdfReadException.damaged("A type 4 function needs a stream and a /Range.")
            }
            let text = try decodeStream(stream)
            var at = 0
            skipSpace(text, &at)
            if at >= text.count || text[at] != UInt8(ascii: "{") { throw PdfReadException.damaged("A type 4 function does not start with a brace.") }
            at += 1
            let made = PostScript()
            made.program = try parseBlock(text, &at, 0)
            made.inputs = domain.count / 2
            made.outputs = range.count / 2
            return made
        }

        private static func parseBlock(_ text: [UInt8], _ at: inout Int, _ depth: Int) throws -> [Op] {
            if depth > maxNesting { throw PdfReadException.damaged("A type 4 function nests too deep.") }
            var ops: [Op] = []
            var blocks: [[Op]] = []
            while true {
                skipSpace(text, &at)
                if at >= text.count { throw PdfReadException.damaged("A type 4 function is not closed.") }
                let b = text[at]
                if b == UInt8(ascii: "}") {
                    at += 1
                    return ops
                }
                if b == UInt8(ascii: "{") {
                    at += 1
                    blocks.append(try parseBlock(text, &at, depth + 1))
                    continue
                }
                let start = at
                while at < text.count && !PdfLexer.isWhiteSpace(Int(text[at])) && text[at] != UInt8(ascii: "{")
                    && text[at] != UInt8(ascii: "}") && text[at] != UInt8(ascii: "%") { at += 1 }
                // Encoding.ASCII turns a byte past 127 into "?".
                let word = String(String.UnicodeScalarView(text[start..<at].map { $0 < 128 ? Unicode.Scalar($0) : "?" }))
                if let number = parseNumber(word) {
                    ops.append(Op(.push, number))
                } else if word == "if", let body = blocks.last {
                    ops.append(Op(.if, body: body))
                    blocks.removeAll()
                } else if word == "ifelse", blocks.count >= 2 {
                    ops.append(Op(.ifElse, body: blocks[blocks.count - 2], otherwise: blocks[blocks.count - 1]))
                    blocks.removeAll()
                } else if let code = words[word] {
                    ops.append(Op(code))
                } else {
                    throw PdfReadException.damaged("A type 4 function uses \"\(word)\".")
                }
            }
        }

        // double.TryParse with NumberStyles.Float and the invariant culture: a sign, digits with a point, an
        // exponent; "Infinity" and "NaN" too. Double(_:) alone would also take hex floats and "inf".
        private static func parseNumber(_ word: String) -> Double? {
            let scalars = Array(word.unicodeScalars)
            var at = 0
            if at < scalars.count && (scalars[at] == "+" || scalars[at] == "-") { at += 1 }
            let rest = String(String.UnicodeScalarView(scalars[at...])).lowercased()
            if rest == "infinity" || rest == "nan" { return Double(word) }
            var digits = 0
            while at < scalars.count && scalars[at].value >= 0x30 && scalars[at].value <= 0x39 {
                at += 1
                digits += 1
            }
            if at < scalars.count && scalars[at] == "." {
                at += 1
                while at < scalars.count && scalars[at].value >= 0x30 && scalars[at].value <= 0x39 {
                    at += 1
                    digits += 1
                }
            }
            if digits == 0 { return nil }
            if at < scalars.count && (scalars[at] == "e" || scalars[at] == "E") {
                at += 1
                if at < scalars.count && (scalars[at] == "+" || scalars[at] == "-") { at += 1 }
                var exponent = 0
                while at < scalars.count && scalars[at].value >= 0x30 && scalars[at].value <= 0x39 {
                    at += 1
                    exponent += 1
                }
                if exponent == 0 { return nil }
            }
            return at == scalars.count ? Double(word) : nil
        }

        private static func skipSpace(_ text: [UInt8], _ at: inout Int) {
            while at < text.count {
                if PdfLexer.isWhiteSpace(Int(text[at])) {
                    at += 1
                } else if text[at] == UInt8(ascii: "%") {
                    while at < text.count && text[at] != 10 && text[at] != 13 { at += 1 }
                } else {
                    break
                }
            }
        }

        override func compute(_ input: [Double], _ output: inout [Double]) throws {
            var stack = [Value](repeating: Value(), count: PostScript.stackSize)
            var top = 0
            for x in input {
                stack[top] = Value(number: x)
                top += 1
            }
            try PostScript.run(program, &stack, &top)
            if top < outputs { throw PdfReadException.damaged("A type 4 function leaves too few results.") }
            for i in 0..<outputs { output[i] = stack[top - outputs + i].number }
        }

        private static func run(_ ops: [Op], _ s: inout [Value], _ top: inout Int) throws {
            for op in ops {
                switch op.code {
                case .push:
                    try need(0, top, 1)
                    s[top] = Value(number: op.value)
                    top += 1
                case .true:
                    try need(0, top, 1)
                    s[top] = Value(number: 1, isBoolean: true)
                    top += 1
                case .false:
                    try need(0, top, 1)
                    s[top] = Value(number: 0, isBoolean: true)
                    top += 1
                case .if:
                    try need(1, top, 0)
                    top -= 1
                    if s[top].number != 0, let body = op.body { try run(body, &s, &top) }
                case .ifElse:
                    try need(1, top, 0)
                    top -= 1
                    if let branch = s[top].number != 0 ? op.body : op.otherwise { try run(branch, &s, &top) }
                case .pop:
                    try need(1, top, 0)
                    top -= 1
                case .dup:
                    try need(1, top, 1)
                    s[top] = s[top - 1]
                    top += 1
                case .exch:
                    try need(2, top, 0)
                    s.swapAt(top - 1, top - 2)
                case .copy:
                    try need(1, top, 0)
                    top -= 1
                    let n = PdfFunction.toInt32(s[top].number)
                    if n < 0 || n > top || top + n > stackSize { throw overflow() }
                    for i in 0..<n { s[top + i] = s[top - n + i] }
                    top += n
                case .index:
                    try need(1, top, 0)
                    let n = PdfFunction.toInt32(s[top - 1].number)
                    if n < 0 || n >= top - 1 { throw overflow() }
                    s[top - 1] = s[top - 2 - n]
                case .roll:
                    try need(2, top, 0)
                    top -= 1
                    let j = PdfFunction.toInt32(s[top].number)
                    top -= 1
                    let n = PdfFunction.toInt32(s[top].number)
                    if n < 0 || n > top { throw overflow() }
                    if n > 1 { roll(&s, top - n, n, j) }
                case .abs, .ceiling, .cos, .cvi, .cvr, .floor, .ln, .log, .neg, .round, .sin, .sqrt, .truncate, .not:
                    try need(1, top, 0)
                    s[top - 1] = unary(op.code, s[top - 1])
                default:
                    try need(2, top, 0)
                    s[top - 2] = binary(op.code, s[top - 2], s[top - 1])
                    top -= 1
                }
            }
        }

        private static func need(_ required: Int, _ top: Int, _ push: Int) throws {
            if top < required { throw PdfReadException.damaged("A type 4 function pops an empty stack.") }
            if top + push > stackSize { throw overflow() }
        }

        private static func overflow() -> PdfReadException {
            PdfReadException.damaged("A type 4 function breaks the stack limits.")
        }

        private static func roll(_ s: inout [Value], _ start: Int, _ length: Int, _ shift: Int) {
            var j = shift % length
            if j < 0 { j += length }
            if j == 0 { return }
            let end = start + length
            s[(end - j)..<end].reverse()
            s[start..<(end - j)].reverse()
            s[start..<end].reverse()
        }

        private static func unary(_ code: Code, _ v: Value) -> Value {
            let x = v.number
            if code == .not { return v.isBoolean ? flag(x == 0) : Value(number: Double(~PdfFunction.toInt64(x))) }
            let result: Double
            switch code {
            case .abs: result = abs(x)
            case .ceiling: result = x.rounded(.up)
            case .cos: result = cos(x * Double.pi / 180)
            case .cvi, .truncate: result = x.rounded(.towardZero)
            case .floor: result = x.rounded(.down)
            case .ln: result = log(x)
            case .log: result = log10(x)
            case .neg: result = -x
            case .round: result = (x + 0.5).rounded(.down)
            case .sin: result = sin(x * Double.pi / 180)
            case .sqrt: result = x.squareRoot()
            default: result = x
            }
            return Value(number: result)
        }

        private static func binary(_ code: Code, _ a: Value, _ b: Value) -> Value {
            let x = a.number, y = b.number
            let logical = a.isBoolean && b.isBoolean
            switch code {
            case .eq: return flag(x == y)
            case .ne: return flag(x != y)
            case .gt: return flag(x > y)
            case .ge: return flag(x >= y)
            case .lt: return flag(x < y)
            case .le: return flag(x <= y)
            case .and: return logical ? flag(x != 0 && y != 0) : Value(number: Double(PdfFunction.toInt64(x) & PdfFunction.toInt64(y)))
            case .or: return logical ? flag(x != 0 || y != 0) : Value(number: Double(PdfFunction.toInt64(x) | PdfFunction.toInt64(y)))
            case .xor: return logical ? flag((x != 0) != (y != 0)) : Value(number: Double(PdfFunction.toInt64(x) ^ PdfFunction.toInt64(y)))
            default: break
            }
            let result: Double
            switch code {
            case .add: result = x + y
            case .sub: result = x - y
            case .mul: result = x * y
            case .div: result = y == 0 ? 0 : x / y
            case .idiv:
                let d = PdfFunction.toInt64(y)
                result = d == 0 ? 0 : d == -1 ? -Double(PdfFunction.toInt64(x)) : Double(PdfFunction.toInt64(x) / d)
            case .mod:
                let d = PdfFunction.toInt64(y)
                result = d == 0 || d == -1 ? 0 : Double(PdfFunction.toInt64(x) % d)
            case .exp: result = pow(x, y)
            case .atan: result = degrees(x, y)
            case .bitshift:
                // Math.Min with a NaN gives NaN, which the C# cast turns into 0.
                if y >= 0 {
                    result = Double(PdfFunction.toInt64(x) << PdfFunction.toInt32(y.isNaN ? y : min(y, 62)))
                } else {
                    result = Double(PdfFunction.toInt64(x) >> PdfFunction.toInt32(-y > 62 ? 62 : -y))
                }
            default: result = 0
            }
            return Value(number: result)
        }

        private static func flag(_ on: Bool) -> Value {
            Value(number: on ? 1 : 0, isBoolean: true)
        }

        private static func degrees(_ numerator: Double, _ denominator: Double) -> Double {
            let angle = atan2(numerator, denominator) * 180 / Double.pi
            return angle < 0 ? angle + 360 : angle
        }
    }
}
