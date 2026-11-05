import Foundation

// Twin of windows/LazyPDF.Core/Crypt/Rc4.cs: the RC4 stream cipher of the standard security handler's V 1, 2 and 4.

enum Rc4 {
    static func apply(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 255
            s.swapAt(i, j)
        }
        var output = [UInt8](repeating: 0, count: data.count)
        var i = 0
        j = 0
        for n in 0..<data.count {
            i = (i + 1) & 255
            j = (j + Int(s[i])) & 255
            s.swapAt(i, j)
            output[n] = data[n] ^ s[(Int(s[i]) + Int(s[j])) & 255]
        }
        return output
    }
}
