import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/CMap.cs: a CMap (ISO 32000-1 9.7.5, 9.10.3): the codespace that
// cuts a string into character codes, and what the codes map to, character ids for a composite font or text
// for a ToUnicode map. Codes are at most four bytes; a four-byte code above 0x7FFFFFFF is a negative int.
// Text is kept as UTF-16 units, as in the C#, so that the last unit of a bfrange can step; a lone surrogate
// in a destination string reads back as U+FFFD, since a Swift String cannot hold one.
public final class CMap {
    private static let maxCodespaces = 100
    private static let maxEntries = 1_000_000

    struct Codespace {
        var length: Int
        var lo: UInt32
        var hi: UInt32
    }

    private static let cacheLock = NSLock()
    private static var predefineds: [String: CMap] = [:]

    let cids = CodeRanges<Int>()
    let notdefs = CodeRanges<Int>()
    let texts = CodeRanges<[UInt16]>()
    var spaceList: [Codespace] = []

    private var spaces: [Codespace] = []
    private var parent: CMap?
    private var isIdentity = false
    private var codesAreUnicode = false

    private init() {
    }

    /// The CMapName, when the file gives one.
    public internal(set) var name: String?

    /// Writing mode 1: glyphs advance downwards (/WMode).
    public internal(set) var isVertical = false

    /// True for a predefined name this library has no table for; its codes are read as two bytes and its CIDs as the codes.
    public private(set) var isFallback = false

    var full: Bool {
        cids.count + notdefs.count + texts.count >= Self.maxEntries
    }

    /// Reads an embedded CMap or a ToUnicode stream. Malformed parts are skipped and what came before
    /// them kept; the work is linear in the data and at most a million mappings are kept. The stream's
    /// /UseCMap, when it has one, is passed as `useCMap`; a "usecmap" in the data names a predefined
    /// CMap and takes its place.
    public static func parse(_ data: [UInt8], useCMap: CMap? = nil) -> CMap {
        let map = CMap()
        map.parent = useCMap
        CMapParser.run(data, map)
        map.finish()
        return map
    }

    /// The predefined CMap of that name: Identity-H and Identity-V, and Adobe's CJK ones that map
    /// to CIDs (UniGB-UCS2-H, 90ms-RKSJ-H, ETen-B5-V and the rest of the Japan1, GB1, CNS1 and Korea1 sets).
    /// Any other name gives a two-byte fallback with `isFallback` set.
    public static func predefined(_ name: String) -> CMap {
        cacheLock.lock()
        let known = predefineds[name]
        cacheLock.unlock()
        if let known {
            return known
        }
        let loaded: CMap? = name == "Identity-H" || name == "Identity-V" ? identity(name) : load(name)
        // A name that is none of them comes from the file, so it is not remembered.
        guard let loaded else {
            return fallback(name)
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = predefineds[name] {
            return existing
        }
        predefineds[name] = loaded
        return loaded
    }

    private static func identity(_ name: String) -> CMap {
        let map = CMap()
        map.name = name
        map.isVertical = name == "Identity-V"
        map.isIdentity = true
        map.spaceList.append(Codespace(length: 2, lo: 0, hi: 0xFFFF))
        map.finish()
        return map
    }

    private static func fallback(_ name: String) -> CMap {
        let map = identity(name)
        map.isVertical = name.hasSuffix("-V")
        map.isFallback = true
        return map
    }

    private static func load(_ name: String) -> CMap? {
        guard let blob = CMapData.blob(name) else {
            return nil
        }
        let map = CMap()
        map.name = name
        map.codesAreUnicode = name.hasPrefix("Uni")
        CMapParser.readPacked(TableBlob.inflate(blob), map)
        map.finish()
        return map
    }

    func setParent(_ parent: CMap) {
        if self.parent == nil {
            self.parent = parent
        }
    }

    func finish() {
        cids.freeze()
        notdefs.freeze()
        texts.freeze()
        if let parent {
            for s in parent.spaces where spaceList.count < Self.maxCodespaces {
                spaceList.append(s)
            }
        }
        if spaceList.isEmpty {
            // No codespace given: accept any byte at the lengths the mappings use.
            let mask = cids.lengthMask | notdefs.lengthMask | texts.lengthMask
            for n in 1...4 where mask & (1 << n) != 0 {
                spaceList.append(Codespace(length: n, lo: 0, hi: n == 4 ? UInt32.max : (1 << UInt32(8 * n)) - 1))
            }
        }
        spaces = spaceList
    }

    /// Cuts the next character code off `bytes` (ISO 32000-1 9.7.6.3): the shortest prefix inside a
    /// codespace range, ranges of different lengths mixed. Bytes that match no range are consumed as many
    /// as the shortest range that starts like them takes, so the string stays in step. Gives length 0 for
    /// empty input.
    public func nextCode(_ bytes: ArraySlice<UInt8>) -> (code: Int, length: Int) {
        if bytes.isEmpty {
            return (0, 0)
        }
        let start = bytes.startIndex
        var code: UInt32 = 0
        for n in 1...min(4, bytes.count) {
            code = code << 8 | UInt32(bytes[start + n - 1])
            for s in spaces where s.length == n && Self.within(s, code) {
                return (Self.signed(code), n)
            }
        }

        var take = 0, shortest = 0
        let first = UInt32(bytes[start])
        for s in spaces {
            shortest = shortest == 0 ? s.length : min(shortest, s.length)
            let shift = UInt32(8 * (s.length - 1))
            if first >= (s.lo >> shift) & 0xFF && first <= (s.hi >> shift) & 0xFF {
                take = take == 0 ? s.length : min(take, s.length)
            }
        }
        if take == 0 {
            take = shortest == 0 ? 1 : shortest
        }
        take = min(take, bytes.count)
        code = 0
        for i in 0..<take {
            code = code << 8 | UInt32(bytes[start + i])
        }
        return (Self.signed(code), take)
    }

    private static func signed(_ code: UInt32) -> Int {
        Int(Int32(truncatingIfNeeded: code))
    }

    private static func within(_ s: Codespace, _ code: UInt32) -> Bool {
        for i in 0..<s.length {
            let shift = UInt32(8 * (s.length - 1 - i))
            let b = (code >> shift) & 0xFF
            if b < (s.lo >> shift) & 0xFF || b > (s.hi >> shift) & 0xFF {
                return false
            }
        }
        return true
    }

    // The code lengths to try: all four when it is not known, else just that one.
    private static func lengths(_ length: Int) -> ClosedRange<Int>? {
        let lower = max(length, 1), upper = length == 0 ? 4 : length
        return lower <= upper ? lower...upper : nil
    }

    /// The character id of a code, or nil when the CMap maps it to none. A code in a notdefrange gives that
    /// range's id. Without the code's length, the shortest length that has a mapping is taken; pass the
    /// length as `nextCode` reports it for a code of known byte length.
    public func cidOf(_ code: Int, length: Int = 0) -> Int? {
        let c = UInt32(truncatingIfNeeded: code)
        return findCid(c, length, false) ?? findCid(c, length, true)
    }

    private func findCid(_ code: UInt32, _ length: Int, _ notdef: Bool) -> Int? {
        if isIdentity {
            return notdef || code > 0xFFFF ? nil : Int(code)
        }
        let table = notdef ? notdefs : cids
        if let range = Self.lengths(length) {
            for n in range where table.lengthMask & (1 << n) != 0 {
                if let found = table.tryFind(n, code) {
                    if notdef {
                        return found.value
                    }
                    // (int)(code - lo) and the sum wrap in the C#.
                    return Int(Int32(truncatingIfNeeded: found.value) &+ Int32(truncatingIfNeeded: code &- found.lo))
                }
            }
        }
        return parent?.findCid(code, length, notdef)
    }

    /// The text a ToUnicode CMap gives a code (a bfchar or bfrange), or nil. One code may give several characters.
    public func unicodeOf(_ code: Int, length: Int = 0) -> String? {
        let c = UInt32(truncatingIfNeeded: code)
        if let range = Self.lengths(length) {
            for n in range where texts.lengthMask & (1 << n) != 0 {
                if var found = texts.tryFind(n, c) {
                    if c != found.lo, let last = found.value.last {
                        found.value[found.value.count - 1] = UInt16(truncatingIfNeeded: UInt32(last) &+ (c &- found.lo))
                    }
                    return String(decoding: found.value, as: UTF16.self)
                }
            }
        }
        if codesAreUnicode {
            return Self.fromUtf16Code(c)
        }
        return parent?.unicodeOf(code, length: length)
    }

    // The Uni*-UCS2 and Uni*-UTF16 CMaps take Unicode itself as the code; UTF-16 pairs fill four bytes.
    private static func fromUtf16Code(_ code: UInt32) -> String? {
        if code <= 0xFFFF {
            return Unicode.Scalar(code).map { String($0) }
        }
        let high = UInt16(truncatingIfNeeded: code >> 16), low = UInt16(truncatingIfNeeded: code)
        return UTF16.isLeadSurrogate(high) && UTF16.isTrailSurrogate(low) ? String(decoding: [high, low], as: UTF16.self) : nil
    }
}
