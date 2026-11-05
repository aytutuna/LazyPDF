import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/ProgramsGoldenTests.cs: the same cases, except
// SyntheticFontIsTheBuilderOutput, which checks the C# builder against the font file and needs no Swift twin. The
// golden files and Tests/Fixtures/golden/programs/synthetic.ttf are written by the Windows tests.

final class ProgramsGoldenTests: XCTestCase {
    func test_standardNamesAreTheGoldenFile() throws {
        try Golden.check("programs", "standard-names-output.txt", ProgramsGolden.standardNamesDump())
    }

    func test_trueTypeIsTheGoldenFile() throws {
        try Golden.check("programs", "truetype-output.txt", ProgramsGolden.trueType(try ProgramsGolden.fixture("synthetic.ttf")))
    }

    func test_subsetIsTheGoldenFile() throws {
        try Golden.check("programs", "subset-output.txt", ProgramsGolden.subset(try ProgramsGolden.fixture("synthetic.ttf")))
    }

    func test_embeddedFontIsTheGoldenFile() throws {
        try Golden.check("programs", "embedded-output.txt", ProgramsGolden.embedded(try ProgramsGolden.fixture("synthetic.ttf")))
    }

    func test_cffIsTheGoldenFile() throws {
        try Golden.check("programs", "cff-output.txt", ProgramsGolden.cff(try Golden.input("programs", "cff-input.txt")))
    }

    func test_type1IsTheGoldenFile() throws {
        try Golden.check("programs", "type1-output.txt", ProgramsGolden.type1())
    }

    func test_damagedFontsAreTheGoldenFile() throws {
        try Golden.check("programs", "damaged-output.txt", ProgramsGolden.damaged(try ProgramsGolden.fixture("synthetic.ttf")))
    }
}
