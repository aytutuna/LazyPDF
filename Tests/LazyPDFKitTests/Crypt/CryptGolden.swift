import Foundation
import XCTest
#if canImport(Security)
import Security
#endif
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Crypt/CryptGolden.cs. One line of input is "<op> <words>"; the result is what
// the key algorithms, the password preparation and the two handlers made of them, in text. Passwords are escaped
// UTF-8 bytes ("-" is the empty password), byte values are hex ("-" is none). The certificates and the sealed
// files are the ones the Windows engine wrote. Without Security.framework the publickey cases are left out.
enum CryptGolden {
    static let hasPublicKey: Bool = {
        #if canImport(Security)
        return true
        #else
        return false
        #endif
    }()

    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("crypt")

    private static func file(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
    }

    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            let words = line.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
            if words[0] == "publickey" && !hasPublicKey { continue }
            output += "> \(line)\n< \(try op(words[0], Array(words.dropFirst())))\n"
        }
        return output
    }

    private static func op(_ op: String, _ words: [String]) throws -> String {
        do {
            switch op {
            case "password":
                let text = text(words.first)
                return "prepare=\(Hex.string(PdfPasswords.prepare(text))) decompose=\(Hex.string(PdfPasswords.decompose(text))) " +
                    "legacy=\(Hex.string(PdfPasswords.legacy(text)))"
            case "hash":
                return Hex.string(PdfKeys.hash(Int(words[0]) ?? 0, Array(text(words[1]).utf8), Hex.bytes(words[2]), optional(words[3])))
            case "legacy":
                return legacy(Int(words[0]) ?? 0, Int(words[1]) ?? 0, words[2] == "1", text(words[3]), text(words[4]), optional(words[5]))
            case "perms":
                let fileKey = Hex.bytes(words[0])
                let p = Int(words[1]) ?? 0
                let perms = PdfKeys.perms(fileKey, p, Hex.bytes(words[2]))
                return "\(Hex.string(perms)) match=\(bool(PdfKeys.permsMatch(fileKey, perms, p, true)))"
            case "fixture":
                return try fixture(words[0], text(words[1]))
            case "certificate":
                return try describe(try file("\(words[0])-cert.der"))
            case "recipients":
                return try recipients(words[0])
            case "publickey":
                return try publicKey(words[0], words[1])
            default:
                preconditionFailure("No op \"\(op)\".")
            }
        } catch let error as PdfReadException {
            let problem = "\(error.problem)"
            return "error \(problem): \(Golden.escape(error.message))"
        }
    }

    private static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func text(_ word: String?) -> String {
        guard let word, word != "-" else { return "" }
        return String(decoding: Golden.unescape(word), as: UTF8.self)
    }

    private static func optional(_ word: String) -> [UInt8] {
        word == "-" ? [] : Hex.bytes(word)
    }

    private static func legacy(_ r: Int, _ length: Int, _ metadata: Bool, _ user: String, _ owner: String, _ id: [UInt8]) -> String {
        let userBytes = PdfPasswords.legacy(user), ownerBytes = PdfPasswords.legacy(owner)
        let o = PdfKeys.ownerValue(ownerBytes, userBytes, r, length)
        let key = PdfKeys.fileKey(PdfKeys.pad(userBytes), o, -4, id, r, length, metadata)
        let u = PdfKeys.userValue(key, id, r)
        let hidden = PdfKeys.userPasswordFromOwner(ownerBytes, o, r, length)
        return "o=\(Hex.string(o)) key=\(Hex.string(key)) u=\(Hex.string(u)) hidden=\(Hex.string(hidden)) " +
            "check=\(bool(PdfKeys.checkUser(key, u, id, r)))"
    }

    private static func fixture(_ name: String, _ password: String) throws -> String {
        let file = try EncryptedFixture.load(name)
        guard let security = try PdfSecurity.open(file.encrypt, file.id, password) else { return "none" }
        let plain = security.decryptStream(4, 0, file.content, file.contentDictionary)
        return "owner=\(bool(security.openedAsOwner)) revision=\(security.revision) permissions=\(security.permissions.rawValue) " +
            "metadata=\(bool(security.encryptMetadata)) perms-mismatch=\(bool(security.permsMismatch)) content=\(Hex.string(plain))"
    }

    // The two lines of a sealed file: the /Encrypt dictionary in PDF syntax, and the hex of the string as object 4's string.
    private static func sealed(_ name: String) throws -> (dictionary: PdfDictionary, cipher: [UInt8]) {
        let lines = String(decoding: try file(name), as: UTF8.self).split(separator: "\n").map { String($0) }
        let dictionary = try XCTUnwrap(try PdfLexer(PdfArrayBytes(Array(lines[0].utf8))).readObject() as? PdfDictionary)
        return (dictionary, Hex.bytes(lines[1]))
    }

    private static func trimmed(_ serial: [UInt8]) -> String {
        String(Hex.string(serial).drop { $0 == "0" })
    }

    private static func describe(_ certificate: [UInt8]) throws -> String {
        let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate))
        return "issuer=\(Hex.string(identity.issuer)) serial=\(trimmed(identity.serial)) key-id=\(Hex.string(identity.keyIdentifier ?? []))"
    }

    private static func recipients(_ name: String) throws -> String {
        let (dictionary, _) = try sealed(name)
        let cf = try XCTUnwrap(dictionary["CF"] as? PdfDictionary)
        let filter = try XCTUnwrap(cf[try XCTUnwrap((dictionary["StmF"] as? PdfName)?.value)] as? PdfDictionary)
        let entries = try XCTUnwrap(filter["Recipients"] as? PdfArray).items.compactMap { ($0 as? PdfString)?.bytes }
        var parts = ["entries=\(entries.count)"]
        for entry in entries {
            let envelope = try XCTUnwrap(PdfCms.decode(entry))
            let info = try XCTUnwrap(envelope.recipients.first)
            let who = info.serial.map { "serial=\(trimmed($0))" } ?? "key-id=\(Hex.string(info.keyIdentifier ?? []))"
            parts.append("key=\(info.algorithm) content=\(envelope.contentAlgorithm) \(who)")
        }
        return parts.joined(separator: " | ")
    }

    private static func publicKey(_ name: String, _ holder: String) throws -> String {
        #if canImport(Security)
        let (dictionary, cipher) = try sealed(name)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(try file("\(holder)-cert.der")) as CFData))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        let key = try XCTUnwrap(SecKeyCreateWithData(Data(try file("\(holder)-key.der")) as CFData, attributes as CFDictionary, nil))
        guard let security = try PdfSecurity.openPublicKey(dictionary, PdfCertificate(certificate: certificate, privateKey: key)) else {
            return "none"
        }
        let plain = security.decryptString(4, 0, cipher)
        return "owner=\(bool(security.openedAsOwner)) revision=\(security.revision) permissions=\(security.permissions.rawValue) " +
            "public-key=\(bool(security.isPublicKey)) text=\(Golden.escape(plain))"
        #else
        return ""
        #endif
    }
}
