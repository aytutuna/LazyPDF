import XCTest
@testable import LazyPDFKit

// No C# twin; PdfDigitalIdInteropTests.cs opens the file this writes. The iteration counts are the ones .NET writes
// (2000) and its loader accepts (at most 300 000 for the MAC and for each key derivation).

final class Pkcs12WriterTests: XCTestCase {
    private func written() throws -> [UInt8] {
        let certificate = try XCTUnwrap(X509Certificate(SignatureFixtures.read("id-cert.der")))
        return try Pkcs12Writer.write(certificate, SignatureFixtures.read("id-key.pkcs1"), password: SignatureFixtures.password)
    }

    private func macIterations(_ pfx: [UInt8]) throws -> Int {
        var outer = AsnReader(pfx)
        var file = try outer.readSequence()
        _ = try file.readInteger()
        _ = try file.readEncodedValue()
        var mac = try file.readSequence()
        _ = try mac.readEncodedValue()
        _ = try mac.readOctetString()
        return try mac.readInt()
    }

    private func derivationIterations(_ pfx: [UInt8]) throws -> [Int] {
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]
        var counts: [Int] = []
        var from = 0
        while let at = pfx.indexOf(oid, from: from) {
            var reader = AsnReader(Array(pfx[(at + oid.count)...]))
            var parameters = try reader.readSequence()
            _ = try parameters.readOctetString()
            counts.append(try parameters.readInt())
            from = at + oid.count
        }
        return counts
    }

    func test_theIterationCountsAreTheOnesDotNetWritesAndLoads() throws {
        let pfx = try written()

        XCTAssertEqual(try macIterations(pfx), 2000)
        XCTAssertEqual(try derivationIterations(pfx), [2000, 2000])
    }

    func test_theFileIsProtectedWithPBES2AndAES256() throws {
        let hex = try written().map { String(format: "%02X", $0) }.joined()

        XCTAssertTrue(hex.contains("2A864886F70D01050D"))
        XCTAssertTrue(hex.contains("60864801650304012A"))
        XCTAssertFalse(hex.contains("2A864886F70D010C0103"))
        XCTAssertFalse(hex.contains("2A864886F70D010C0106"))
    }

    func test_theFixtureTheCSharpOpensHoldsTheSameStructure() throws {
        if ProcessInfo.processInfo.environment["LAZYPDF_WRITE_GOLDEN"] == "1" {
            try Data(written()).write(to: SignatureFixtures.folder.appendingPathComponent("swift-export.pfx"))
        }
        let fixture = try SignatureFixtures.read("swift-export.pfx")

        XCTAssertEqual(try macIterations(fixture), 2000)
        XCTAssertEqual(try derivationIterations(fixture), [2000, 2000])
    }
}
