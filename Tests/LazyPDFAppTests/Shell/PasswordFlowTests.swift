import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PasswordFlowTests.cs: a locked file, the question, retries, giving up, and what a file
// that only the owner restricts does.

@MainActor
final class PasswordFlowTests: XCTestCase {
    func test_aFileWithAPasswordAsksForIt() async {
        let f = ViewModelFixture(self)

        await f.vm.open(f.locked())

        XCTAssertTrue(f.vm.documents.isEmpty)
        let request = f.vm.passwordRequest
        XCTAssertEqual(request?.name, "locked.pdf")
        XCTAssertEqual(request?.needsCertificate, false)
        XCTAssertEqual(request?.attempts, 0)
        XCTAssertNil(request?.problem)
    }

    func test_theRightPasswordOpensItAndEndsTheQuestion() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())

        await f.vm.submitPassword("secret")

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(f.vm.documents.first?.title, "locked.pdf")
        XCTAssertEqual(f.vm.documents.first?.isDirty, false)
    }

    func test_aWrongPasswordSaysSoAndAsksAgain() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())

        await f.vm.submitPassword("wrong")
        let first = f.vm.passwordRequest
        await f.vm.submitPassword("still wrong")
        let second = f.vm.passwordRequest

        XCTAssertEqual(first?.problem, "That password is not right.")
        XCTAssertEqual(first?.attempts, 1)
        XCTAssertEqual(second?.attempts, 2)
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_aRetryAfterAMistakeStillWorks() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())
        await f.vm.submitPassword("wrong")

        await f.vm.submitPassword("secret")

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_givingUpDropsTheFileAndOpensNothing() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())

        f.vm.cancelPending()

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_theOwnerPasswordOpensItToo() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked("aes.pdf", fixture: "crypt-aes128.pdf"))

        await f.vm.submitPassword("owner")

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_severalLockedFilesAreAskedAboutOneAfterTheOther() async {
        let f = ViewModelFixture(self)
        let first = f.locked("one.pdf")
        let second = f.locked("two.pdf", fixture: "crypt-aes128.pdf")

        await f.vm.open([first, second])
        XCTAssertEqual(f.vm.passwordRequest?.name, "one.pdf")
        await f.vm.submitPassword("secret")

        XCTAssertEqual(f.vm.passwordRequest?.name, "two.pdf")
        await f.vm.submitPassword("secret")
        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.documents.map(\.title), ["one.pdf", "two.pdf"])
    }

    func test_aFileOnlyTheOwnerRestrictsOpensWithNoQuestion() async {
        let f = ViewModelFixture(self)
        let url = f.locked("owner.pdf", fixture: "owner-only-aes.pdf")

        await f.vm.open(url)

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_anAes256FileOpensWithItsPassword() async {
        let f = ViewModelFixture(self)
        let url = f.locked("aes256.pdf", fixture: "crypt-aes256.pdf")

        await f.vm.open(url)
        await f.vm.submitPassword("secret")

        XCTAssertEqual(f.vm.documents.count, 1)
    }
}
