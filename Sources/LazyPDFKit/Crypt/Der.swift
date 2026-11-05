import Foundation

// No C# twin: System.Security.Cryptography.Pkcs reads and writes CMS in the C#. Here the few DER shapes of an
// EnvelopedData and of a certificate's names are read and written by hand (ITU-T X.690). A reader refuses
// anything it does not know: high tag numbers and lengths past the bytes. Indefinite lengths (BER) are read, to a
// depth of maxDepth, because writers of CMS use them.

struct DerNode {
    let tag: Int
    /// Where the tag byte is.
    let start: Int
    /// The bytes after the tag and the length, without the end-of-contents pair of an indefinite length.
    let content: Range<Int>
    /// Where the next node starts: past the content, and past the end-of-contents pair.
    let end: Int
}

struct DerReader {
    static let maxDepth = 32

    let bytes: [UInt8]

    func node(at position: Int, limit: Int, depth: Int = 0) -> DerNode? {
        guard position >= 0, limit >= 2, limit <= bytes.count, position <= limit - 2 else { return nil }
        let tag = Int(bytes[position])
        if tag & 0x1F == 0x1F { return nil }
        var length = Int(bytes[position + 1])
        var at = position + 2
        if length == 0x80 { return indefinite(tag, position, limit, depth) }
        if length > 0x80 {
            let count = length & 0x7F
            if count > 4 || at + count > limit { return nil }
            length = 0
            for i in 0..<count { length = (length << 8) | Int(bytes[at + i]) }
            at += count
        }
        guard length <= limit - at else { return nil }
        return DerNode(tag: tag, start: position, content: at..<at + length, end: at + length)
    }

    // X.690 8.1.3.6: a constructed node whose children run up to a pair of zero bytes.
    private func indefinite(_ tag: Int, _ start: Int, _ limit: Int, _ depth: Int) -> DerNode? {
        guard tag & 0x20 != 0, depth < DerReader.maxDepth else { return nil }
        let first = start + 2
        var position = first
        while position <= limit - 2 {
            if bytes[position] == 0 && bytes[position + 1] == 0 {
                return DerNode(tag: tag, start: start, content: first..<position, end: position + 2)
            }
            guard let child = node(at: position, limit: limit, depth: depth + 1) else { return nil }
            position = child.end
        }
        return nil
    }

    /// The first node; bytes after it are left alone, as EnvelopedCms leaves them.
    func root() -> DerNode? {
        node(at: 0, limit: bytes.count)
    }

    func children(of node: DerNode) -> [DerNode]? {
        var result: [DerNode] = []
        var position = node.content.lowerBound
        while position < node.content.upperBound {
            guard let child = self.node(at: position, limit: node.content.upperBound) else { return nil }
            result.append(child)
            position = child.end
        }
        return result
    }

    func content(of node: DerNode) -> [UInt8] {
        Array(bytes[node.content])
    }

    /// The bytes of an OCTET STRING, or of a constructed one: the pieces joined (X.690 8.7.3); nil when a piece is not one.
    func octets(of node: DerNode, depth: Int = 0) -> [UInt8]? {
        guard node.tag & 0x20 != 0 else { return content(of: node) }
        guard depth < DerReader.maxDepth, let pieces = children(of: node) else { return nil }
        var joined: [UInt8] = []
        for piece in pieces {
            guard piece.tag == 0x04 || piece.tag == 0x24, let part = octets(of: piece, depth: depth + 1) else { return nil }
            joined += part
        }
        return joined
    }

    /// The tag, the length and the content.
    func whole(of node: DerNode) -> [UInt8] {
        Array(bytes[node.start..<node.end])
    }

    /// An object identifier as dotted numbers; nil for another tag or an arc too large to hold.
    func oid(_ node: DerNode) -> String? {
        guard node.tag == 0x06, !node.content.isEmpty else { return nil }
        var arcs: [Int] = []
        var value = 0
        var open = false
        for byte in bytes[node.content] {
            if value > Int.max >> 8 { return nil }
            value = (value << 7) | Int(byte & 0x7F)
            open = byte & 0x80 != 0
            if !open {
                arcs.append(value)
                value = 0
            }
        }
        guard !open, let first = arcs.first else { return nil }
        let head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
        return (head + arcs.dropFirst()).map { String($0) }.joined(separator: ".")
    }
}

enum DerWriter {
    static func node(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var output = [tag]
        let count = content.count
        if count < 0x80 {
            output.append(UInt8(count))
        } else {
            var length: [UInt8] = []
            var rest = count
            while rest > 0 {
                length.insert(UInt8(rest & 0xFF), at: 0)
                rest >>= 8
            }
            output.append(0x80 | UInt8(length.count))
            output += length
        }
        return output + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        node(0x30, items.flatMap { $0 })
    }

    static func set(_ items: [[UInt8]]) -> [UInt8] {
        node(0x31, items.flatMap { $0 })
    }

    static func octetString(_ content: [UInt8]) -> [UInt8] {
        node(0x04, content)
    }

    static let null: [UInt8] = [0x05, 0x00]

    /// A small non-negative integer.
    static func integer(_ value: Int) -> [UInt8] {
        node(0x02, [UInt8(truncatingIfNeeded: value)])
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { Int($0) ?? 0 }
        var content: [UInt8] = [UInt8(truncatingIfNeeded: arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var group = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                group.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            content += group
        }
        return node(0x06, content)
    }
}
