import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/CMapParser.cs: reads the PostScript subset CMaps are written in
// (ISO 32000-1 9.10.3, Adobe Technical Note 5014) into a CMap, and the packed form of the predefined ones
// (see CMapData).
enum CMapParser {
    private static let wMode = Array("WMode".utf8)
    private static let cMapName = Array("CMapName".utf8)
    private static let useCMap = Array("usecmap".utf8)

    static func run(_ data: [UInt8], _ map: CMap) {
        var lx = CMapLexer(data)
        var lastName: ArraySlice<UInt8> = []
        var kind = lx.next()
        while kind != .end && !map.full {
            if kind == .name {
                lastName = lx.text
                if lastName.elementsEqual(wMode) && lx.next() == .number {
                    map.isVertical = lx.number == 1
                } else if lastName.elementsEqual(cMapName) && lx.next() == .name {
                    map.name = Latin1.string(Array(lx.text))
                }
            } else if kind == .word && lx.text.elementsEqual(useCMap) {
                let parent = CMap.predefined(Latin1.string(Array(lastName)))
                if !parent.isFallback {
                    map.setParent(parent)
                }
            } else if kind == .word {
                section(&lx, map)
            }
            kind = lx.next()
        }
    }

    private static func section(_ lx: inout CMapLexer, _ map: CMap) {
        let word = lx.text
        if word.elementsEqual("begincodespacerange".utf8) { codeSpaces(&lx, map) }
        else if word.elementsEqual("begincidrange".utf8) { cidRanges(&lx, map.cids, map) }
        else if word.elementsEqual("begincidchar".utf8) { cidChars(&lx, map.cids, map) }
        else if word.elementsEqual("beginnotdefrange".utf8) { cidRanges(&lx, map.notdefs, map) }
        else if word.elementsEqual("beginnotdefchar".utf8) { cidChars(&lx, map.notdefs, map) }
        else if word.elementsEqual("beginbfrange".utf8) { bfRanges(&lx, map) }
        else if word.elementsEqual("beginbfchar".utf8) { bfChars(&lx, map) }
    }

    private static func codeSpaces(_ lx: inout CMapLexer, _ map: CMap) {
        while lx.next() == .hex {
            guard let lo = lx.code(), lx.next() == .hex, let hi = lx.code() else {
                return
            }
            if lo.length == hi.length && map.spaceList.count < 100 {
                map.spaceList.append(CMap.Codespace(length: lo.length, lo: lo.code, hi: hi.code))
            }
        }
    }

    private static func cidRanges(_ lx: inout CMapLexer, _ into: CodeRanges<Int>, _ map: CMap) {
        while lx.next() == .hex && !map.full {
            guard let lo = lx.code(), lx.next() == .hex, let hi = lx.code(), lx.next() == .number else {
                return
            }
            if lo.length == hi.length && lo.code <= hi.code && (0...Int(Int32.max)).contains(lx.number) {
                into.add(lo.length, lo.code, hi.code, lx.number)
            }
        }
    }

    private static func cidChars(_ lx: inout CMapLexer, _ into: CodeRanges<Int>, _ map: CMap) {
        while lx.next() == .hex && !map.full {
            guard let code = lx.code(), lx.next() == .number else {
                return
            }
            if (0...Int(Int32.max)).contains(lx.number) {
                into.add(code.length, code.code, code.code, lx.number)
            }
        }
    }

    private static func bfChars(_ lx: inout CMapLexer, _ map: CMap) {
        while lx.next() == .hex && !map.full {
            guard let code = lx.code() else {
                return
            }
            let kind = lx.next()
            let text: [UInt16]
            if kind == .hex {
                text = lx.utf16()
            } else if kind == .name {
                text = GlyphList.unicodeOf(Latin1.string(Array(lx.text))).map { Array($0.utf16) } ?? []
            } else {
                return
            }
            if !text.isEmpty {
                map.texts.add(code.length, code.code, code.code, text)
            }
        }
    }

    private static func bfRanges(_ lx: inout CMapLexer, _ map: CMap) {
        while lx.next() == .hex && !map.full {
            guard let lo = lx.code(), lx.next() == .hex, let hi = lx.code() else {
                return
            }
            let kind = lx.next()
            if kind == .hex {
                let text = lx.utf16()
                if lo.length == hi.length && lo.code <= hi.code && !text.isEmpty {
                    map.texts.add(lo.length, lo.code, hi.code, text)
                }
            } else if kind == .arrayOpen {
                var code = lo.code
                while lx.next() == .hex {
                    let text = lx.utf16()
                    if lo.length == hi.length && code <= hi.code && !text.isEmpty && !map.full {
                        map.texts.add(lo.length, code, code, text)
                    }
                    code &+= 1
                }
            } else {
                return
            }
        }
    }

    // The packed layout, written by the script that made CMapData: varints, zigzag for the id deltas.
    static func readPacked(_ b: [UInt8], _ map: CMap) {
        var at = 0
        map.isVertical = varint(b, &at) == 1
        let nameLength = varint(b, &at)
        if nameLength > 0 {
            map.setParent(CMap.predefined(String(decoding: b[at..<at + nameLength], as: UTF8.self)))
        }
        at += nameLength

        var spaces = varint(b, &at)
        while spaces > 0 {
            let n = Int(b[at])
            at += 1
            let lo = UInt32(truncatingIfNeeded: varint(b, &at))
            let hi = UInt32(truncatingIfNeeded: varint(b, &at))
            map.spaceList.append(CMap.Codespace(length: n, lo: lo, hi: hi))
            spaces -= 1
        }
        var groups = varint(b, &at)
        while groups > 0 {
            let n = Int(b[at])
            at += 1
            var lo: UInt32 = 0
            var cid = 0
            var count = varint(b, &at)
            while count > 0 {
                lo &+= UInt32(truncatingIfNeeded: varint(b, &at))
                let span = UInt32(truncatingIfNeeded: varint(b, &at))
                let zigzag = varint(b, &at)
                cid += (zigzag >> 1) ^ -(zigzag & 1)
                map.cids.add(n, lo, lo &+ span, Int(Int32(truncatingIfNeeded: cid)))
                cid += Int(span) + 1
                count -= 1
            }
            groups -= 1
        }
    }

    private static func varint(_ b: [UInt8], _ at: inout Int) -> Int {
        var value = 0
        var shift = 0
        while true {
            let x = b[at]
            at += 1
            value |= Int(x & 0x7F) << shift
            if x & 0x80 == 0 {
                return value
            }
            shift += 7
        }
    }
}
