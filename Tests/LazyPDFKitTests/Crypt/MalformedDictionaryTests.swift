import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/MalformedDictionaryTests.cs: the same cases, and one more with no C# twin:
// RandomlyDamagedDictionariesNeverTrap, which checks what Swift can do that C# cannot, trap, on values a file may hold.

final class MalformedDictionaryTests: XCTestCase {
    private let id = SyntheticEncryption.id

    private func problem(of dictionary: PdfDictionary, file: StaticString = #filePath, line: UInt = #line) -> PdfReadProblem? {
        do {
            _ = try PdfSecurity.open(dictionary, id, "")
            XCTFail("The dictionary opened.", file: file, line: line)
        } catch let error as PdfReadException {
            return error.problem
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
        return nil
    }

    func test_otherSecurityHandlerIsUnsupported() {
        let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
        dictionary["Filter"] = PdfName("Adobe.PubSec")

        XCTAssertEqual(problem(of: dictionary), .unsupported)
    }

    func test_missingFilterIsUnsupported() {
        let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
        dictionary["Filter"] = nil

        XCTAssertEqual(problem(of: dictionary), .unsupported)
    }

    func test_unknownVersionOrRevisionIsUnsupported() {
        for (v, r) in [(0, 2), (3, 3), (6, 7), (2, 6), (5, 4)] {
            let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
            dictionary["V"] = PdfNumber(v)
            dictionary["R"] = PdfNumber(r)

            XCTAssertEqual(problem(of: dictionary), .unsupported, "V \(v) R \(r)")
        }
    }

    func test_unknownCryptFilterMethodIsUnsupported() {
        let dictionary = SyntheticEncryption.legacy(4, 4, 128, "", "o", cfm: "AESV9").dictionary

        XCTAssertEqual(problem(of: dictionary), .unsupported)
    }

    func test_aes256FilterOnR4IsUnsupported() {
        let dictionary = SyntheticEncryption.legacy(4, 4, 128, "", "o", cfm: "AESV3").dictionary

        XCTAssertEqual(problem(of: dictionary), .unsupported)
    }

    func test_rc4FilterOnR6IsUnsupported() throws {
        let dictionary = SyntheticEncryption.modern(6, "", "o").dictionary
        let cf = try XCTUnwrap(dictionary["CF"] as? PdfDictionary)
        let filter = try XCTUnwrap(cf["StdCF"] as? PdfDictionary)
        filter["CFM"] = PdfName("V2")

        XCTAssertEqual(problem(of: dictionary), .unsupported)
    }

    func test_streamFilterMissingFromCfIsDamaged() {
        let dictionary = SyntheticEncryption.legacy(4, 4, 128, "", "o", cfm: "AESV2", stmF: "Nope").dictionary

        XCTAssertEqual(problem(of: dictionary), .damaged)
    }

    func test_missingPasswordValueIsDamaged() {
        for key in ["O", "U"] {
            let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
            dictionary[key] = nil

            XCTAssertEqual(problem(of: dictionary), .damaged, key)
        }
    }

    func test_shortPasswordValueIsDamaged() {
        for key in ["O", "U"] {
            let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
            dictionary[key] = PdfString(bytes: [UInt8](repeating: 0, count: 20), isHex: true)

            XCTAssertEqual(problem(of: dictionary), .damaged, key)
        }
    }

    func test_shortModernValueIsDamaged() {
        for key in ["O", "U", "OE", "UE"] {
            let dictionary = SyntheticEncryption.modern(6, "", "o").dictionary
            dictionary[key] = PdfString(bytes: [UInt8](repeating: 0, count: 10), isHex: true)

            XCTAssertEqual(problem(of: dictionary), .damaged, key)
        }
    }

    func test_emptyIdJustFailsThePasswordCheck() throws {
        let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary

        XCTAssertNil(try PdfSecurity.open(dictionary, [], ""))
    }

    func test_oversizedKeyLengthIsClamped() throws {
        let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
        dictionary["Length"] = PdfNumber(100000)

        XCTAssertNotNil(try PdfSecurity.open(dictionary, id, ""))
    }

    func test_passwordValueOfTheWrongTypeIsDamaged() {
        let dictionary = SyntheticEncryption.legacy(2, 3, 128, "", "o").dictionary
        dictionary["O"] = PdfName("NotAString")

        XCTAssertEqual(problem(of: dictionary), .damaged)
    }

    func test_randomlyDamagedDictionariesNeverTrap() throws {
        var random = SeededRandom(33)
        let keys = ["Filter", "V", "R", "Length", "P", "CF", "StmF", "StrF", "EFF", "O", "U", "OE", "UE", "Perms", "EncryptMetadata"]
        let methods = ["V2", "AESV2", "AESV3", "None", "Bogus"]
        let names = ["StdCF", "Identity", "Rc4CF", "Nope"]
        func damage(_ dictionary: PdfDictionary, _ key: String, _ random: inout SeededRandom) {
            switch random.next() % 10 {
            case 0: dictionary[key] = nil
            case 1: dictionary[key] = PdfNumber(Int(Int32(truncatingIfNeeded: random.next())))
            case 2: dictionary[key] = PdfNumber("99999999999999999999")
            case 3: dictionary[key] = PdfNumber("1e999")
            case 4: dictionary[key] = PdfName(names[Int(random.next() % 4)])
            case 5: dictionary[key] = PdfString(bytes: random.bytes(Int(random.next() % 70)), isHex: true)
            case 6: dictionary[key] = PdfArray([])
            case 7: dictionary[key] = PdfBoolean(false)
            case 8: dictionary[key] = PdfNull.instance
            default: break
            }
        }
        for i in 0..<150 {
            let built = [SyntheticEncryption.legacy(2, 3, 128, "", "o"), SyntheticEncryption.legacy(4, 4, 128, "", "o", cfm: "AESV2"),
                         SyntheticEncryption.legacy(1, 2, 40, "", "o"), SyntheticEncryption.modern(5, "", "o"),
                         SyntheticEncryption.modern(6, "", "o")][i % 5]
            let dictionary = built.dictionary.copy()
            for key in keys where random.next() % 4 == 0 { damage(dictionary, key, &random) }
            if let cf = dictionary["CF"] as? PdfDictionary, let filter = cf["StdCF"] as? PdfDictionary, random.next() % 2 == 0 {
                filter["CFM"] = PdfName(methods[Int(random.next() % 5)])
            }
            do {
                if let security = try PdfSecurity.open(dictionary, id, "") {
                    let data = random.bytes(Int(random.next() % 50))
                    _ = security.decryptString(7, 0, data)
                    _ = security.encryptStream(7, 0, data, dictionary)
                    _ = security.permissions
                }
            } catch is PdfReadException {
            }
        }
    }
}
