import XCTest
@testable import LazyPDFApp

final class CertificateChoiceTests: XCTestCase {
    private func choice(_ name: String, valid: Bool) -> CertificateChoice {
        CertificateChoice(id: name, name: name, issuer: "Test", expires: Date(), isValidNow: valid)
    }

    func test_validOnesComeFirstThenByName() {
        let ordered = CertificateChoice.order([choice("Zeta", valid: true), choice("Expired", valid: false), choice("alpha", valid: true)])

        XCTAssertEqual(ordered.map(\.name), ["alpha", "Zeta", "Expired"])
        XCTAssertEqual(ordered.map(\.isValidNow), [true, true, false])
    }
}
