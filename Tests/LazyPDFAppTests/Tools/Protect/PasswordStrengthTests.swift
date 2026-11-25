import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/protect/PasswordStrengthTests.cs.

final class PasswordStrengthTests: XCTestCase {
    func test_wordsAreRatedByLengthAndVariety() {
        let cases: [(String, PasswordRating)] = [
            ("", .none), ("aaaaaaaaaaaaaaaa", .weak), ("password1", .weak), ("abcdefgh", .weak), ("12345678901234567890", .weak),
            ("passwordpassword1234", .weak), ("Tr0ub4dor&3", .fair), ("Tr0ub4dor&3x", .good), ("correct horse battery staple", .strong),
        ]
        for (password, expected) in cases {
            XCTAssertEqual(PasswordStrength.rate(password), expected, password)
        }
    }

    func test_aLongerWordIsNeverRatedBelowItsPrefix() {
        let word = Array("Zq7!mK2#vX9$pL4@wR8%")
        let rated = (1...word.count).map { PasswordStrength.rate(String(word[..<$0])) }

        XCTAssertEqual(rated, rated.sorted())
    }

    func test_everyRatingBeyondNoneHasAHint() {
        for strength in [PasswordRating.weak, .fair, .good, .strong] {
            XCTAssertFalse(PasswordStrength.hint(strength).isEmpty)
        }
        XCTAssertTrue(PasswordStrength.hint(.none).isEmpty)
    }
}
