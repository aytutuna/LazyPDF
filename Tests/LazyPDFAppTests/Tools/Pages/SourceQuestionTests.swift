import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The question a source file asks (SourcePasswordWindow and SourceCertificateWindow of the Windows app, which have no test of their
// own) and the identities the window offers for it.

@MainActor
final class SourceQuestionTests: XCTestCase {
    private func asked(_ question: SourceQuestion) async {
        await waitUntil { question.asking != nil }
    }

    func test_aPasswordQuestionWaitsForTheAnswer() async throws {
        let question = SourceQuestion()
        let job = Task { await question.password(for: "b.pdf", wrong: false) }
        await asked(question)

        XCTAssertEqual(question.asking?.kind, .password)
        XCTAssertEqual(question.asking?.name, "b.pdf")
        XCTAssertNil(question.asking?.problem)
        question.answer(password: "secret")

        let answer = await job.value
        XCTAssertEqual(answer, "secret")
        XCTAssertNil(question.asking)
    }

    func test_aWrongPasswordIsSaidInTheNextQuestion() async throws {
        let question = SourceQuestion()
        let job = Task { await question.password(for: "b.pdf", wrong: true) }
        await asked(question)

        XCTAssertEqual(question.asking?.problem, "That password is not right.")
        question.giveUp()
        let answer = await job.value
        XCTAssertNil(answer)
    }

    func test_theCertificateQuestionListsTheIdentitiesAndSaysWhenThereIsNone() async throws {
        let question = SourceQuestion()
        question.choices = { [FakeKeys.alice] }
        let job = Task { await question.certificate(for: "b.pdf", wrong: true) }
        await asked(question)

        XCTAssertEqual(question.asking?.kind, .certificate)
        XCTAssertEqual(question.asking?.choices, [FakeKeys.alice])
        XCTAssertEqual(question.asking?.problem, "That certificate does not open this file.")
        question.answer(certificate: FakeKeys.alice)
        let chosen = await job.value
        XCTAssertEqual(chosen, FakeKeys.alice)

        question.choices = { [] }
        let none = Task { await question.certificate(for: "b.pdf", wrong: false) }
        await asked(question)
        XCTAssertEqual(question.asking?.problem, "No certificate with a private key was found on this computer.")
        question.giveUp()
        let nothing = await none.value
        XCTAssertNil(nothing)
    }

    func test_closingTheQuestionTwiceDoesNothing() async {
        let question = SourceQuestion()

        question.giveUp()
        question.giveUp()

        XCTAssertNil(question.asking)
    }

    func test_theWindowOffersTheIdentitiesOfTheKeychain() async {
        let fixture = ViewModelFixture(self)

        XCTAssertEqual(fixture.vm.certificateChoices(), [FakeKeys.alice])
        XCTAssertTrue(RecordingHost().certificateChoices().isEmpty)
    }
}
